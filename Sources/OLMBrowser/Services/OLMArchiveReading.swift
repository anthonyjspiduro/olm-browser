import Foundation

enum ArchiveReaderError: LocalizedError {
    case unsupportedFile
    case unreadableArchive
    case noMessagesFound

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            "Choose a Microsoft Outlook .olm archive."
        case .unreadableArchive:
            "The selected archive could not be opened for reading."
        case .noMessagesFound:
            "The archive opened, but no Outlook message folders were found."
        }
    }
}

protocol OLMArchiveReading: Sendable {
    func openArchive(at url: URL) throws -> ArchiveSnapshot
    func loadMessages(in folderID: MailFolder.ID, offset: Int, limit: Int) throws -> MessagePage
    func buildSearchIndex(progress: @escaping @Sendable (IndexProgress) -> Void) throws
    func searchMessages(matching query: String, limit: Int) throws -> [MessageSummary]
}
