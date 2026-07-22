import AppKit
import Foundation

@MainActor
final class ArchiveStore: ObservableObject {
    @Published private(set) var snapshot: ArchiveSnapshot?
    @Published var selectedFolderID: MailFolder.ID?
    @Published var selectedMessageID: MessageSummary.ID?
    @Published var searchText = ""
    @Published var errorMessage: String?
    @Published private(set) var isOpening = false
    @Published private(set) var isLoadingPage = false
    @Published private(set) var isSearching = false
    @Published private(set) var messages: [MessageSummary] = []
    @Published private(set) var searchResults: [MessageSummary] = []
    @Published private(set) var indexProgress = IndexProgress(indexed: 0, total: 0, isComplete: false)

    private let reader: any OLMArchiveReading
    private let pageSize = 100
    private var nextPageOffset = 0
    private var totalMessagesInFolder = 0
    private var searchTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?

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
        searchText.isEmpty && nextPageOffset < totalMessagesInFolder
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

        Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try reader.openArchive(at: url)
                }.value
                snapshot = loaded
                searchText = ""
                selectedFolderID = loaded.folders.first(where: { $0.kind == .inbox })?.id
                    ?? loaded.folders.first?.id
                resetPageState()
                loadNextPage()
                startIndexing()
            } catch {
                errorMessage = error.localizedDescription
            }
            isOpening = false
        }
    }

    func folderSelectionChanged() {
        searchText = ""
        searchResults = []
        searchTask?.cancel()
        resetPageState()
        loadNextPage()
    }

    func loadNextPage() {
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
            isSearching = false
            selectedMessageID = messages.first?.id
            return
        }

        isSearching = true
        let reader = reader
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                let results = try await Task.detached(priority: .userInitiated) {
                    try reader.searchMessages(matching: query, limit: 500)
                }.value
                guard !Task.isCancelled, searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else {
                    return
                }
                searchResults = results
                selectedMessageID = results.first?.id
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
            isSearching = false
        }
    }

    func closeArchive() {
        searchTask?.cancel()
        indexTask?.cancel()
        snapshot = nil
        selectedFolderID = nil
        selectedMessageID = nil
        searchText = ""
        messages = []
        searchResults = []
        resetPageState()
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
            do {
                try await Task.detached(priority: .utility) {
                    try reader.buildSearchIndex { progress in
                        Task { @MainActor [weak self] in
                            self?.indexProgress = progress
                        }
                    }
                }.value
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }
}
