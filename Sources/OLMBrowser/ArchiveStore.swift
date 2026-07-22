import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ArchiveStore: ObservableObject {
    @Published private(set) var snapshot: ArchiveSnapshot?
    @Published private(set) var archiveSessionID = UUID()
    @Published var selectedFolderID: MailFolder.ID?
    @Published var selectedMessageID: MessageSummary.ID?
    @Published var searchText = ""
    @Published var searchSort: SearchSort = .relevance
    @Published var isSearchFolderScoped = false
    @Published var errorMessage: String?
    @Published private(set) var isOpening = false
    @Published private(set) var isLoadingPage = false
    @Published private(set) var isSearching = false
    @Published private(set) var messages: [MessageSummary] = []
    @Published private(set) var searchResults: [MessageSummary] = []
    @Published private(set) var indexProgress = IndexProgress(indexed: 0, total: 0, isComplete: false)
    @Published private(set) var inlineImages: [String: String] = [:]
    @Published private(set) var operationalStatus: ArchiveOperationalStatus?
    @Published private(set) var unreadCountsAreAccurate = false

    private let reader: any OLMArchiveReading
    private let pageSize = 100
    private var nextPageOffset = 0
    private var totalMessagesInFolder = 0
    private var nextSearchOffset = 0
    private var totalSearchResults = 0
    private var searchTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var openTask: Task<Void, Never>?
    private var inlineImageTask: Task<Void, Never>?
    private let attachmentFiles = AttachmentFileStore()

    init(reader: any OLMArchiveReading = NativeOLMArchiveReader()) {
        self.reader = reader
    }

    var selectedFolder: MailFolder? {
        snapshot?.folders.first { $0.id == selectedFolderID }
    }

    var visibleMessages: [MessageSummary] {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? messages
            : searchResults
    }

    var selectedMessage: MessageSummary? {
        visibleMessages.first { $0.id == selectedMessageID }
    }

    var hasMoreMessages: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nextPageOffset < totalMessagesInFolder
            : nextSearchOffset < totalSearchResults
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Outlook Archive"
        panel.message = "OLM Browser opens the archive in place and never modifies it."
        panel.prompt = "Open OLM"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        guard !isOpening else { return }
        isOpening = true
        errorMessage = nil
        let reader = reader

        openTask?.cancel()
        openTask = Task {
            let worker = Task.detached(priority: .userInitiated) { try reader.openArchive(at: url) }
            do {
                let loaded = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else { isOpening = false; return }
                archiveSessionID = UUID()
                unreadCountsAreAccurate = false
                snapshot = loaded
                searchText = ""
                selectedFolderID = loaded.folders.first(where: { $0.kind == .inbox })?.id
                    ?? loaded.folders.first?.id
                resetPageState()
                loadNextPage()
                startIndexing()
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
            isOpening = false
            refreshOperationalStatus()
        }
    }

    func cancelOpening() {
        openTask?.cancel()
        isOpening = false
    }

    func folderSelectionChanged() {
        searchText = ""
        searchResults = []
        searchTask?.cancel()
        resetPageState()
        loadNextPage()
    }

    func loadNextPage() {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            loadNextSearchPage()
            return
        }
        guard !isLoadingPage, hasMoreMessages || nextPageOffset == 0,
              let folderID = selectedFolderID else { return }
        isLoadingPage = true
        let offset = nextPageOffset
        let limit = pageSize
        let reader = reader

        Task {
            do {
                let page = try await Task.detached(priority: .userInitiated) {
                    try reader.loadMessages(in: folderID, offset: offset, limit: limit)
                }.value
                guard selectedFolderID == folderID else {
                    isLoadingPage = false
                    return
                }
                messages.append(contentsOf: page.messages)
                nextPageOffset = page.nextOffset
                totalMessagesInFolder = page.totalCount
                if selectedMessageID == nil { selectedMessageID = messages.first?.id }
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoadingPage = false
        }
    }

    func searchTextChanged() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            nextSearchOffset = 0
            totalSearchResults = 0
            isSearching = false
            selectedMessageID = messages.first?.id
            return
        }

        searchResults = []
        nextSearchOffset = 0
        totalSearchResults = 0
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await performSearch(query: query, offset: 0)
        }
    }

    func searchOptionsChanged() {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        searchTextChanged()
    }

    private func loadNextSearchPage() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isSearching, !isLoadingPage, nextSearchOffset < totalSearchResults else { return }
        isLoadingPage = true
        searchTask = Task { await performSearch(query: query, offset: nextSearchOffset) }
    }

    private func performSearch(query: String, offset: Int) async {
        let reader = reader
        let scope = isSearchFolderScoped ? selectedFolderID : nil
        let sort = searchSort
        do {
            let page = try await Task.detached(priority: .userInitiated) {
                try reader.searchMessages(
                    matching: query, folderID: scope, offset: offset, limit: 100, sort: sort
                )
            }.value
            guard !Task.isCancelled,
                  searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query,
                  searchSort == sort,
                  (isSearchFolderScoped ? selectedFolderID : nil) == scope else { return }
            if offset == 0 { searchResults = page.messages }
            else { searchResults.append(contentsOf: page.messages) }
            nextSearchOffset = page.nextOffset
            totalSearchResults = page.totalCount
            if offset == 0 { selectedMessageID = page.messages.first?.id }
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
        isSearching = false
        isLoadingPage = false
    }

    var searchResultTotal: Int { totalSearchResults }

    func closeArchive() {
        searchTask?.cancel()
        indexTask?.cancel()
        inlineImageTask?.cancel()
        snapshot = nil
        unreadCountsAreAccurate = false
        archiveSessionID = UUID()
        selectedFolderID = nil
        selectedMessageID = nil
        searchText = ""
        messages = []
        searchResults = []
        resetPageState()
        attachmentFiles.cleanupSession()
    }

    func applicationWillTerminate() {
        openTask?.cancel()
        searchTask?.cancel()
        indexTask?.cancel()
        inlineImageTask?.cancel()
        attachmentFiles.cleanupSession()
    }

    func cancelIndexing() { indexTask?.cancel() }

    func rebuildSearchIndex() {
        indexTask?.cancel()
        let reader = reader
        Task {
            do {
                try await Task.detached(priority: .utility) { try reader.resetSearchIndex() }.value
                clearFolderUnreadCounts()
                indexProgress = IndexProgress(indexed: 0, total: snapshot?.folders.reduce(0) { $0 + $1.messageCount } ?? 0, isComplete: false)
                startIndexing()
            } catch { errorMessage = error.localizedDescription }
            refreshOperationalStatus()
        }
    }

    func deleteSearchCache() {
        indexTask?.cancel()
        let reader = reader
        Task {
            do {
                try await Task.detached(priority: .utility) { try reader.deleteSearchCache() }.value
                clearFolderUnreadCounts()
                indexProgress = IndexProgress(indexed: 0, total: snapshot?.folders.reduce(0) { $0 + $1.messageCount } ?? 0, isComplete: false)
                searchResults = []
            } catch { errorMessage = error.localizedDescription }
            refreshOperationalStatus()
        }
    }

    func refreshOperationalStatus() {
        guard snapshot != nil else { operationalStatus = nil; return }
        operationalStatus = reader.operationalStatus()
    }

    func exportDiagnosticReport() {
        guard let snapshot, let operationalStatus else {
            errorMessage = "Archive diagnostics are not available yet."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Diagnostic Report"
        panel.nameFieldStringValue = "OLM Browser Diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let data = try DiagnosticReportExporter.data(
                snapshot: snapshot,
                status: operationalStatus,
                indexProgress: indexProgress
            )
            try data.write(to: destination, options: [.atomic])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestOpenExternalLink(_ candidate: URL) {
        guard let destination = ExternalLinkPolicy.approvedDestination(candidate) else {
            errorMessage = "Only secure HTTPS links can be opened."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Open External Link?"
        alert.informativeText = "This will open \(destination.host ?? "the website") in your default browser. The website can learn your IP address, access time, and browser activity."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Link")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.open(destination)
    }

    func loadInlineImages(for message: MessageSummary) {
        inlineImageTask?.cancel()
        inlineImages = [:]
        let candidates = message.attachments.filter {
            $0.isAvailable && $0.contentID != nil && $0.contentType.lowercased().hasPrefix("image/")
                && $0.byteCount <= 20 * 1_024 * 1_024
        }
        guard !candidates.isEmpty else { return }
        let reader = reader
        let messageID = message.id
        inlineImageTask = Task {
            let images = await Task.detached(priority: .userInitiated) {
                var result: [String: String] = [:]
                var total = 0
                for attachment in candidates {
                    guard !Task.isCancelled, total < 64 * 1_024 * 1_024,
                          let cid = attachment.contentID.map(Self.normalizedContentID), !cid.isEmpty,
                          let data = try? reader.attachmentData(for: attachment),
                          total + data.count <= 64 * 1_024 * 1_024 else { continue }
                    total += data.count
                    result[cid.lowercased()] = "data:\(Self.safeImageMIMEType(attachment.contentType));base64,\(data.base64EncodedString())"
                }
                return result
            }.value
            guard !Task.isCancelled, selectedMessage?.id == messageID else { return }
            inlineImages = images
        }
    }

    private nonisolated static func normalizedContentID(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
    }

    private nonisolated static func safeImageMIMEType(_ value: String) -> String {
        let allowed = ["image/png", "image/jpeg", "image/gif", "image/webp", "image/tiff", "image/bmp", "image/heic", "image/svg+xml"]
        let normalized = value.lowercased().split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
        return allowed.contains(normalized) ? normalized : "application/octet-stream"
    }

    func previewAttachment(_ attachment: AttachmentSummary) {
        guard attachment.isAvailable else {
            errorMessage = attachment.diagnostic?.description ?? "The attachment is unavailable."
            return
        }
        let reader = reader
        let files = attachmentFiles
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try files.temporaryFile(for: attachment, reader: reader)
                }.value
                AttachmentPreviewController.shared.present(url)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func saveAttachment(_ attachment: AttachmentSummary) {
        guard attachment.isAvailable else {
            errorMessage = attachment.diagnostic?.description ?? "The attachment is unavailable."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save Attachment"
        panel.nameFieldStringValue = AttachmentFileStore.safeFilename(attachment.filename)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let reader = reader
        let files = attachmentFiles
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try files.export(attachment, to: destination, reader: reader)
                }.value
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func exportAllAttachments(from message: MessageSummary) {
        let panel = NSOpenPanel()
        panel.title = "Export All Attachments"
        panel.prompt = "Export"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let reader = reader
        let files = attachmentFiles
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try files.exportAll(message.attachments, to: destination, reader: reader)
                }.value
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func exportMessage(_ message: MessageSummary, format: MessageExportFormat) {
        let panel = NSSavePanel()
        panel.title = "Export Message"
        panel.nameFieldStringValue = AttachmentFileStore.safeFilename(message.subject) + ".\(format.rawValue)"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let reader = reader
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let data = try MessageExporter.data(for: message, format: format, reader: reader)
                    try data.write(to: destination, options: [.atomic])
                }.value
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func exportLoadedMessages(format: MessageExportFormat) {
        let selectedMessages = visibleMessages
        guard !selectedMessages.isEmpty else {
            errorMessage = "There are no loaded messages to export."
            return
        }
        let reader = reader
        if format == .csv {
            let panel = NSSavePanel()
            panel.title = "Export Loaded Messages"
            panel.nameFieldStringValue = "OLM Browser Messages.csv"
            panel.allowedContentTypes = [.commaSeparatedText]
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            Task {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        let data = try MessageBatchExporter.csvData(for: selectedMessages)
                        try data.write(to: destination, options: [.atomic])
                    }.value
                } catch { errorMessage = error.localizedDescription }
            }
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Export Loaded Messages as \(format.label)"
        panel.prompt = "Export"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try MessageBatchExporter.exportFiles(
                        selectedMessages,
                        format: format,
                        to: destination,
                        reader: reader
                    )
                }.value
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func attachmentDragProvider(_ attachment: AttachmentSummary) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = AttachmentFileStore.safeFilename(attachment.filename)
        guard attachment.isAvailable else { return provider }
        let type = UTType(mimeType: attachment.contentType)
            ?? UTType(filenameExtension: (attachment.filename as NSString).pathExtension)
            ?? .data
        let reader = reader
        let files = attachmentFiles
        provider.registerFileRepresentation(
            forTypeIdentifier: type.identifier,
            fileOptions: [.openInPlace],
            visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: 1)
            Task.detached(priority: .userInitiated) {
                do {
                    let url = try files.temporaryFile(for: attachment, reader: reader)
                    progress.completedUnitCount = 1
                    completion(url, true, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return progress
        }
        return provider
    }

    private func resetPageState() {
        messages = []
        selectedMessageID = nil
        nextPageOffset = 0
        totalMessagesInFolder = selectedFolder?.messageCount ?? 0
        isLoadingPage = false
    }

    private func startIndexing() {
        indexTask?.cancel()
        let reader = reader
        indexTask = Task {
            let worker = Task.detached(priority: .utility) {
                try reader.buildSearchIndex { progress in
                    Task { @MainActor [weak self] in
                        self?.indexProgress = progress
                        self?.refreshOperationalStatus()
                    }
                }
            }
            do {
                try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                if !Task.isCancelled { applyIndexedFolderMetadata() }
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
            refreshOperationalStatus()
        }
    }

    private func applyIndexedFolderMetadata() {
        guard let counts = reader.folderUnreadCounts(), let current = snapshot else { return }
        let folders = current.folders.map { folder in
            MailFolder(
                id: folder.id,
                accountID: folder.accountID,
                parentID: folder.parentID,
                name: folder.name,
                kind: folder.kind,
                messageCount: folder.messageCount,
                unreadCount: counts[folder.id, default: 0]
            )
        }
        snapshot = ArchiveSnapshot(
            identity: current.identity,
            accounts: current.accounts,
            folders: folders,
            messages: current.messages
        )
        unreadCountsAreAccurate = true
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resetPageState()
            loadNextPage()
        }
    }

    private func clearFolderUnreadCounts() {
        guard let current = snapshot else { unreadCountsAreAccurate = false; return }
        snapshot = ArchiveSnapshot(
            identity: current.identity,
            accounts: current.accounts,
            folders: current.folders.map { folder in
                MailFolder(
                    id: folder.id,
                    accountID: folder.accountID,
                    parentID: folder.parentID,
                    name: folder.name,
                    kind: folder.kind,
                    messageCount: folder.messageCount,
                    unreadCount: 0
                )
            },
            messages: current.messages
        )
        unreadCountsAreAccurate = false
    }
}
