import AppKit
import Foundation
import UniformTypeIdentifiers

enum BrowserMode: String, CaseIterable, Identifiable {
    case mail
    case calendar
    case contacts
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var symbolName: String {
        switch self { case .mail: "envelope"; case .contacts: "person.crop.circle"; case .calendar: "calendar" }
    }
}

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
    @Published private(set) var openProgress: ArchiveOpenProgress?
    @Published private(set) var isLoadingPage = false
    @Published private(set) var isSearching = false
    @Published private(set) var messages: [MessageSummary] = []
    @Published private(set) var searchResults: [MessageSummary] = []
    @Published private(set) var indexProgress = IndexProgress(indexed: 0, total: 0, isComplete: false)
    @Published private(set) var inlineImages: [String: String] = [:]
    @Published private(set) var operationalStatus: ArchiveOperationalStatus?
    @Published private(set) var unreadCountsAreAccurate = false
    @Published private(set) var isLoadingMessageDetail = false
    @Published var browserMode: BrowserMode = .mail
    @Published var selectedContactSourceID: ArchiveItemSource.ID?
    @Published var selectedCalendarSourceID: ArchiveItemSource.ID?
    @Published var selectedContactIDs: Set<ContactRecord.ID> = []
    @Published var selectedCalendarEventIDs: Set<CalendarEventRecord.ID> = []
    @Published var displayedCalendarMonth = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    @Published var selectedCalendarDate = Calendar.current.startOfDay(for: Date())
    @Published private(set) var contacts: [ContactRecord] = []
    @Published private(set) var calendarEvents: [CalendarEventRecord] = []
    @Published private(set) var isLoadingItems = false
    @Published private(set) var itemResultTotal = 0
    @Published private(set) var isExportingItems = false
    @Published private(set) var recentArchives: [RecentArchive] = []

    private let reader: any OLMArchiveReading
    private let archiveAccess = ArchiveAccessManager()
    private var activeSecurityScopedURL: URL?
    private var activeURLDidStartSecurityScope = false
    private let pageSize = 100
    private var nextPageOffset = 0
    private var totalMessagesInFolder = 0
    private var nextSearchOffset = 0
    private var totalSearchResults = 0
    private var searchTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var openTask: Task<Void, Never>?
    private var inlineImageTask: Task<Void, Never>?
    private var messageDetailTask: Task<Void, Never>?
    private let attachmentFiles = AttachmentFileStore()
    private var itemLoadTask: Task<Void, Never>?
    private var nextItemOffset = 0

    init(reader: any OLMArchiveReading = NativeOLMArchiveReader()) {
        self.reader = reader
        recentArchives = archiveAccess.recentArchives
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

    var selectedContacts: [ContactRecord] { contacts.filter { selectedContactIDs.contains($0.id) } }
    var selectedCalendarEvents: [CalendarEventRecord] { calendarEvents.filter { selectedCalendarEventIDs.contains($0.id) } }
    var selectedContact: ContactRecord? { selectedContacts.count == 1 ? selectedContacts[0] : nil }
    var selectedCalendarEvent: CalendarEventRecord? { selectedCalendarEvents.count == 1 ? selectedCalendarEvents[0] : nil }
    var hasMoreItems: Bool { nextItemOffset < itemResultTotal }

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
        guard url.isFileURL else {
            errorMessage = "OLM Browser can only open local archive files."
            return
        }
        searchTask?.cancel()
        indexTask?.cancel()
        inlineImageTask?.cancel()
        messageDetailTask?.cancel()
        itemLoadTask?.cancel()
        isOpening = true
        openProgress = .init(
            phase: "Preparing archive", completedUnits: 0, totalUnits: 0,
            bytesRead: 0, totalBytes: 0
        )
        errorMessage = nil
        let reader = reader
        let didStartSecurityScope = url.startAccessingSecurityScopedResource()

        openTask?.cancel()
        openTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                try reader.openArchive(at: url) { progress in
                    Task { @MainActor [weak self] in
                        guard self?.isOpening == true else { return }
                        self?.openProgress = progress
                    }
                }
            }
            do {
                let loaded = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else {
                    if didStartSecurityScope { url.stopAccessingSecurityScopedResource() }
                    isOpening = false
                    return
                }
                releaseActiveSecurityScope()
                activeSecurityScopedURL = url
                activeURLDidStartSecurityScope = didStartSecurityScope
                archiveAccess.remember(url)
                recentArchives = archiveAccess.recentArchives
                archiveSessionID = UUID()
                unreadCountsAreAccurate = false
                snapshot = loaded
                browserMode = loaded.folders.isEmpty
                    ? (loaded.contactSources.isEmpty ? .calendar : .contacts)
                    : .mail
                searchText = ""
                selectedFolderID = loaded.folders.first(where: { $0.kind == .inbox })?.id
                    ?? loaded.folders.first?.id
                selectedContactSourceID = loaded.contactSources.first?.id
                selectedCalendarSourceID = loaded.calendarSources.first?.id
                resetItemState()
                resetPageState()
                if browserMode == .mail { loadNextPage() } else { loadNextItems() }
                startIndexing()
            } catch {
                if didStartSecurityScope { url.stopAccessingSecurityScopedResource() }
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
            isOpening = false
            openProgress = nil
            refreshOperationalStatus()
        }
    }

    func cancelOpening() {
        openTask?.cancel()
        isOpening = false
        openProgress = nil
    }

    func openRecentArchive(_ archive: RecentArchive) {
        guard let url = archiveAccess.resolveRecent(id: archive.id) else {
            archiveAccess.forget(id: archive.id)
            recentArchives = archiveAccess.recentArchives
            errorMessage = "The recent archive is no longer available. Choose it again to restore access."
            return
        }
        open(url)
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
                if selectedMessageID == nil {
                    selectedMessageID = messages.first?.id
                    selectedMessageChanged()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoadingPage = false
        }
    }

    func messageDidAppear(_ messageID: MessageSummary.ID) {
        let visible = visibleMessages
        let prefetchDistance = min(20, max(5, visible.count / 10))
        guard hasMoreMessages,
              let index = visible.firstIndex(where: { $0.id == messageID }),
              index >= max(0, visible.count - prefetchDistance) else { return }
        loadNextPage()
    }

    func searchTextChanged() {
        guard browserMode == .mail else {
            scheduleItemReload()
            return
        }
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
            if offset == 0 {
                selectedMessageID = page.messages.first?.id
                selectedMessageChanged()
            }
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
        isSearching = false
        isLoadingPage = false
    }

    var searchResultTotal: Int { totalSearchResults }

    func selectedMessageChanged() {
        messageDetailTask?.cancel()
        inlineImageTask?.cancel()
        inlineImages = [:]
        guard let message = selectedMessage else {
            isLoadingMessageDetail = false
            return
        }
        guard !message.isFullyLoaded else {
            isLoadingMessageDetail = false
            loadInlineImages(for: message)
            return
        }
        isLoadingMessageDetail = true
        let selectedID = message.id
        let reader = reader
        messageDetailTask = Task {
            do {
                let detailed = try await Task.detached(priority: .userInitiated) {
                    try reader.loadMessageDetails(for: message)
                }.value
                guard !Task.isCancelled, selectedMessageID == selectedID else { return }
                replaceMessage(detailed)
                isLoadingMessageDetail = false
                loadInlineImages(for: detailed)
            } catch {
                guard !Task.isCancelled, selectedMessageID == selectedID else { return }
                isLoadingMessageDetail = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func closeArchive() {
        searchTask?.cancel()
        indexTask?.cancel()
        inlineImageTask?.cancel()
        messageDetailTask?.cancel()
        itemLoadTask?.cancel()
        snapshot = nil
        unreadCountsAreAccurate = false
        archiveSessionID = UUID()
        selectedFolderID = nil
        selectedContactSourceID = nil
        selectedCalendarSourceID = nil
        selectedMessageID = nil
        searchText = ""
        messages = []
        searchResults = []
        resetItemState()
        resetPageState()
        attachmentFiles.cleanupSession()
        releaseActiveSecurityScope()
    }

    func applicationWillTerminate() {
        openTask?.cancel()
        searchTask?.cancel()
        indexTask?.cancel()
        inlineImageTask?.cancel()
        messageDetailTask?.cancel()
        itemLoadTask?.cancel()
        attachmentFiles.cleanupSession()
        releaseActiveSecurityScope()
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
                        let hydrated = try selectedMessages.map { try reader.loadMessageDetails(for: $0) }
                        let data = try MessageBatchExporter.csvData(for: hydrated)
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
                    let hydrated = try selectedMessages.map { try reader.loadMessageDetails(for: $0) }
                    return try MessageBatchExporter.exportFiles(
                        hydrated,
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

    func browserModeChanged() {
        searchTask?.cancel()
        itemLoadTask?.cancel()
        searchText = ""
        if browserMode == .contacts, selectedContactSourceID == nil {
            selectedContactSourceID = snapshot?.contactSources.first?.id
        } else if browserMode == .calendar, selectedCalendarSourceID == nil {
            selectedCalendarSourceID = snapshot?.calendarSources.first?.id
        }
        resetItemState()
        if browserMode != .mail { loadNextItems() }
    }

    func itemSourceSelectionChanged() {
        guard browserMode != .mail else { return }
        resetItemState()
        loadNextItems()
    }

    func itemDidAppear(_ id: String) {
        let ids = browserMode == .contacts ? contacts.map(\.id) : calendarEvents.map(\.id)
        guard hasMoreItems, let index = ids.firstIndex(of: id), index >= max(0, ids.count - 15) else { return }
        loadNextItems()
    }

    func loadNextItems() {
        guard !isLoadingItems, browserMode != .mail, hasMoreItems || nextItemOffset == 0 else { return }
        isLoadingItems = true
        let mode = browserMode
        let offset = nextItemOffset
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceID = mode == .contacts ? selectedContactSourceID : selectedCalendarSourceID
        let reader = reader
        itemLoadTask = Task {
            do {
                if mode == .contacts {
                    let page = try await Task.detached(priority: .userInitiated) {
                        try reader.loadContacts(sourceID: sourceID, matching: query, offset: offset, limit: 100)
                    }.value
                    guard !Task.isCancelled, browserMode == mode, selectedContactSourceID == sourceID,
                          searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                    if offset == 0 { contacts = page.records } else { contacts.append(contentsOf: page.records) }
                    nextItemOffset = page.nextOffset; itemResultTotal = page.totalCount
                    if offset == 0 { selectedContactIDs = Set(page.records.prefix(1).map(\.id)) }
                } else {
                    let page = try await Task.detached(priority: .userInitiated) {
                        try reader.loadCalendarEvents(sourceID: sourceID, matching: query, offset: offset, limit: Int.max)
                    }.value
                    guard !Task.isCancelled, browserMode == mode, selectedCalendarSourceID == sourceID,
                          searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                    if offset == 0 { calendarEvents = page.records } else { calendarEvents.append(contentsOf: page.records) }
                    nextItemOffset = page.nextOffset; itemResultTotal = page.totalCount
                    if offset == 0 {
                        selectedCalendarEventIDs = Set(page.records.prefix(1).map(\.id))
                        if let first = page.records.first {
                            selectedCalendarDate = Calendar.current.startOfDay(for: first.startAt)
                            displayedCalendarMonth = Calendar.current.dateInterval(of: .month, for: first.startAt)?.start
                                ?? selectedCalendarDate
                        }
                    }
                }
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
            if browserMode == mode { isLoadingItems = false }
        }
    }

    private func scheduleItemReload() {
        itemLoadTask?.cancel()
        itemLoadTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            resetItemState()
            loadNextItems()
        }
    }

    private func resetItemState() {
        contacts = []; calendarEvents = []
        selectedContactIDs = []; selectedCalendarEventIDs = []
        nextItemOffset = 0; itemResultTotal = 0; isLoadingItems = false
    }

    func exportContacts(_ records: [ContactRecord], format: ContactExportFormat) {
        guard !records.isEmpty else { errorMessage = "There are no contacts to export."; return }
        let panel = NSSavePanel()
        panel.title = "Export Contacts"
        panel.nameFieldStringValue = records.count == 1
            ? AttachmentFileStore.safeFilename(records[0].displayName) + ".\(format.rawValue)"
            : "OLM Browser Contacts.\(format.rawValue)"
        panel.allowedContentTypes = format == .csv ? [.commaSeparatedText] : [UTType(filenameExtension: "vcf") ?? .data]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try ContactCalendarExporter.contactData(records, format: format).write(to: destination, options: .atomic) }
        catch { errorMessage = error.localizedDescription }
    }

    func exportCalendarEvents(_ records: [CalendarEventRecord], format: CalendarExportFormat) {
        guard !records.isEmpty else { errorMessage = "There are no calendar events to export."; return }
        let panel = NSSavePanel()
        panel.title = "Export Calendar Events"
        panel.nameFieldStringValue = records.count == 1
            ? AttachmentFileStore.safeFilename(records[0].title) + ".\(format.rawValue)"
            : "OLM Browser Calendar.\(format.rawValue)"
        panel.allowedContentTypes = format == .csv ? [.commaSeparatedText] : [UTType(filenameExtension: "ics") ?? .data]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try ContactCalendarExporter.calendarData(records, format: format).write(to: destination, options: .atomic) }
        catch { errorMessage = error.localizedDescription }
    }

    func exportAllMatchingContacts(format: ContactExportFormat) {
        let panel = NSSavePanel()
        panel.title = "Export All Matching Contacts"
        panel.nameFieldStringValue = "OLM Browser Contacts.\(format.rawValue)"
        panel.allowedContentTypes = format == .csv ? [.commaSeparatedText] : [UTType(filenameExtension: "vcf") ?? .data]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isExportingItems = true
        let sourceID = selectedContactSourceID, query = searchText, reader = reader
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let page = try reader.loadContacts(sourceID: sourceID, matching: query, offset: 0, limit: Int.max)
                    try ContactCalendarExporter.contactData(page.records, format: format).write(to: destination, options: .atomic)
                }.value
            } catch { errorMessage = error.localizedDescription }
            isExportingItems = false
        }
    }

    func exportAllMatchingCalendarEvents(format: CalendarExportFormat) {
        let panel = NSSavePanel()
        panel.title = "Export All Matching Calendar Events"
        panel.nameFieldStringValue = "OLM Browser Calendar.\(format.rawValue)"
        panel.allowedContentTypes = format == .csv ? [.commaSeparatedText] : [UTType(filenameExtension: "ics") ?? .data]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isExportingItems = true
        let sourceID = selectedCalendarSourceID, query = searchText, reader = reader
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let page = try reader.loadCalendarEvents(sourceID: sourceID, matching: query, offset: 0, limit: Int.max)
                    try ContactCalendarExporter.calendarData(page.records, format: format).write(to: destination, options: .atomic)
                }.value
            } catch { errorMessage = error.localizedDescription }
            isExportingItems = false
        }
    }

    private func resetPageState() {
        messageDetailTask?.cancel()
        inlineImageTask?.cancel()
        isLoadingMessageDetail = false
        inlineImages = [:]
        messages = []
        selectedMessageID = nil
        nextPageOffset = 0
        totalMessagesInFolder = selectedFolder?.messageCount ?? 0
        isLoadingPage = false
    }

    private func replaceMessage(_ detailed: MessageSummary) {
        if let index = messages.firstIndex(where: { $0.id == detailed.id }) {
            messages[index] = detailed
        }
        if let index = searchResults.firstIndex(where: { $0.id == detailed.id }) {
            searchResults[index] = detailed
        }
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
            contactSources: current.contactSources,
            calendarSources: current.calendarSources,
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
            contactSources: current.contactSources,
            calendarSources: current.calendarSources,
            messages: current.messages
        )
        unreadCountsAreAccurate = false
    }

    private func releaseActiveSecurityScope() {
        if activeURLDidStartSecurityScope {
            activeSecurityScopedURL?.stopAccessingSecurityScopedResource()
        }
        activeSecurityScopedURL = nil
        activeURLDidStartSecurityScope = false
    }
}
