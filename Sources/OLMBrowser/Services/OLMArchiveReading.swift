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

enum AttachmentAccessError: LocalizedError {
    case unavailable(String)
    case invalidDestination

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .invalidDestination: "The attachment destination is invalid."
        }
    }
}

protocol OLMArchiveReading: Sendable {
    func openArchive(at url: URL) throws -> ArchiveSnapshot
    func loadMessages(in folderID: MailFolder.ID, offset: Int, limit: Int) throws -> MessagePage
    func buildSearchIndex(progress: @escaping @Sendable (IndexProgress) -> Void) throws
    func searchMessages(
        matching query: String,
        folderID: MailFolder.ID?,
        offset: Int,
        limit: Int,
        sort: SearchSort
    ) throws -> MessagePage
    func attachmentData(for attachment: AttachmentSummary) throws -> Data
    func operationalStatus() -> ArchiveOperationalStatus
    func folderUnreadCounts() -> [MailFolder.ID: Int]?
    func resetSearchIndex() throws
    func deleteSearchCache() throws
}
