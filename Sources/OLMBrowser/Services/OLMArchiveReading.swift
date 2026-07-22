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
}
