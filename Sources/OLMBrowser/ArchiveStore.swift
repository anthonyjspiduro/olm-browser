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

    private let reader: any OLMArchiveReading

    init(reader: any OLMArchiveReading = NativeOLMArchiveReader()) {
        self.reader = reader
    }

    var selectedFolder: MailFolder? {
        snapshot?.folders.first { $0.id == selectedFolderID }
    }

    var visibleMessages: [MessageSummary] {
        guard let snapshot else { return [] }
        let folderMessages = snapshot.messages.filter { message in
            selectedFolderID == nil || message.folderID == selectedFolderID
        }
        guard !searchText.isEmpty else { return folderMessages }

        return folderMessages.filter { message in
            message.subject.localizedCaseInsensitiveContains(searchText)
                || message.sender.label.localizedCaseInsensitiveContains(searchText)
                || message.sender.address.localizedCaseInsensitiveContains(searchText)
                || message.preview.localizedCaseInsensitiveContains(searchText)
                || message.body.localizedCaseInsensitiveContains(searchText)
                || message.attachments.contains {
                    $0.filename.localizedCaseInsensitiveContains(searchText)
                }
        }
    }

    var selectedMessage: MessageSummary? {
        snapshot?.messages.first { $0.id == selectedMessageID }
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
                selectedFolderID = loaded.folders.first?.id
                selectedMessageID = loaded.messages.first {
                    $0.folderID == selectedFolderID
                }?.id
                searchText = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            isOpening = false
        }
    }

    func closeArchive() {
        snapshot = nil
        selectedFolderID = nil
        selectedMessageID = nil
        searchText = ""
    }
}
