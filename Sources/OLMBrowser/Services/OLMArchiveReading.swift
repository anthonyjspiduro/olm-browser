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
            "The archive opened, but no supported Outlook mail, contact, or calendar data was found."
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

struct ArchiveOpenProgress: Sendable {
    let phase: String
    let completedUnits: Int
    let totalUnits: Int
    let bytesRead: UInt64
    let totalBytes: UInt64

    var fractionCompleted: Double? {
        guard totalUnits > 0 else { return nil }
        return min(1, max(0, Double(completedUnits) / Double(totalUnits)))
    }
}

protocol OLMArchiveReading: Sendable {
    func openArchive(at url: URL) throws -> ArchiveSnapshot
    func openArchive(
        at url: URL,
        progress: @escaping @Sendable (ArchiveOpenProgress) -> Void
    ) throws -> ArchiveSnapshot
    func loadMessages(in folderID: MailFolder.ID, offset: Int, limit: Int) throws -> MessagePage
    func buildSearchIndex(progress: @escaping @Sendable (IndexProgress) -> Void) throws
    func searchMessages(
        matching query: String,
        folderID: MailFolder.ID?,
        offset: Int,
        limit: Int,
        sort: SearchSort
    ) throws -> MessagePage
    func loadMessageDetails(for message: MessageSummary) throws -> MessageSummary
    func loadContacts(sourceID: ArchiveItemSource.ID?, matching query: String, offset: Int, limit: Int) throws -> ContactPage
    func loadContacts(
        sourceID: ArchiveItemSource.ID?,
        matching query: String,
        offset: Int,
        limit: Int,
        progress: @escaping @Sendable (ArchiveItemLoadProgress) -> Void
    ) throws -> ContactPage
    func loadCalendarEvents(sourceID: ArchiveItemSource.ID?, matching query: String, offset: Int, limit: Int) throws -> CalendarEventPage
    func loadCalendarEvents(
        sourceID: ArchiveItemSource.ID?,
        matching query: String,
        offset: Int,
        limit: Int,
        progress: @escaping @Sendable (ArchiveItemLoadProgress) -> Void
    ) throws -> CalendarEventPage
    func attachmentData(for attachment: AttachmentSummary) throws -> Data
    func operationalStatus() -> ArchiveOperationalStatus
    func folderUnreadCounts() -> [MailFolder.ID: Int]?
    func resetSearchIndex() throws
    func deleteSearchCache() throws
}

extension OLMArchiveReading {
    func openArchive(
        at url: URL,
        progress: @escaping @Sendable (ArchiveOpenProgress) -> Void
    ) throws -> ArchiveSnapshot {
        progress(.init(phase: "Opening archive", completedUnits: 0, totalUnits: 0, bytesRead: 0, totalBytes: 0))
        return try openArchive(at: url)
    }

    func loadContacts(
        sourceID: ArchiveItemSource.ID?,
        matching query: String,
        offset: Int,
        limit: Int,
        progress: @escaping @Sendable (ArchiveItemLoadProgress) -> Void
    ) throws -> ContactPage {
        try loadContacts(sourceID: sourceID, matching: query, offset: offset, limit: limit)
    }

    func loadCalendarEvents(
        sourceID: ArchiveItemSource.ID?,
        matching query: String,
        offset: Int,
        limit: Int,
        progress: @escaping @Sendable (ArchiveItemLoadProgress) -> Void
    ) throws -> CalendarEventPage {
        try loadCalendarEvents(sourceID: sourceID, matching: query, offset: offset, limit: limit)
    }
}
