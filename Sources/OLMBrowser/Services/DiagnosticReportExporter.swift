import Foundation

enum DiagnosticReportExporter {
    static func data(
        snapshot: ArchiveSnapshot,
        status: ArchiveOperationalStatus,
        indexProgress: IndexProgress,
        generatedAt: Date = Date()
    ) throws -> Data {
        let items = status.itemDiagnostics
        let report = Report(
            schemaVersion: 3,
            generatedAt: generatedAt,
            archiveByteCount: snapshot.identity.size,
            accountCount: snapshot.accounts.count,
            folderCount: snapshot.folders.count,
            catalogedMessageCount: snapshot.folders.reduce(0) { $0 + $1.messageCount },
            archiveEntries: status.archiveEntries,
            messageEntries: status.messageEntries,
            attachmentPayloadEntries: status.attachmentEntries,
            duplicateZIPPaths: status.duplicateEntryPaths,
            unreadableMessageEntries: status.failedMessageEntries,
            recoveredMalformedMessageEntries: status.recoveredMalformedMessageEntries,
            checksumFailureEntries: status.checksumFailureEntries,
            unsupportedCompressionEntries: status.unsupportedCompressionEntries,
            searchIndexedEntries: indexProgress.indexed,
            searchTotalEntries: indexProgress.total,
            searchUnreadableEntries: indexProgress.failed,
            searchIndexComplete: indexProgress.isComplete,
            searchCacheByteCount: status.cacheByteCount,
            parsedContactCollections: items.parsedContactCollections,
            failedContactCollections: items.failedContactCollections,
            parsedContacts: items.parsedContacts,
            contactsMissingNames: items.contactsMissingNames,
            contactsWithEmail: items.contactsWithEmail,
            contactsWithPhone: items.contactsWithPhone,
            contactsWithPostalAddress: items.contactsWithPostalAddress,
            contactDistributionLists: items.contactDistributionLists,
            parsedCalendarCollections: items.parsedCalendarCollections,
            failedCalendarCollections: items.failedCalendarCollections,
            parsedCalendarEvents: items.parsedCalendarEvents,
            calendarEventsMissingDates: items.calendarEventsMissingDates,
            calendarEventsMissingTitles: items.calendarEventsMissingTitles,
            recurringCalendarEvents: items.recurringCalendarEvents,
            unsupportedRecurrencePatterns: items.unsupportedRecurrencePatterns,
            recurrenceExceptions: items.recurrenceExceptions,
            cancelledCalendarEvents: items.cancelledCalendarEvents,
            calendarEventsWithTimeZones: items.calendarEventsWithTimeZones,
            privacy: PrivacyStatement(
                containsArchivePath: false,
                containsMessageContent: false,
                containsParticipantData: false,
                containsAttachmentNamesOrPayloads: false,
                containsContactOrCalendarContent: false
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }

    private struct Report: Encodable {
        let schemaVersion: Int
        let generatedAt: Date
        let archiveByteCount: Int64
        let accountCount: Int
        let folderCount: Int
        let catalogedMessageCount: Int
        let archiveEntries: Int
        let messageEntries: Int
        let attachmentPayloadEntries: Int
        let duplicateZIPPaths: Int
        let unreadableMessageEntries: Int
        let recoveredMalformedMessageEntries: Int
        let checksumFailureEntries: Int
        let unsupportedCompressionEntries: Int
        let searchIndexedEntries: Int
        let searchTotalEntries: Int
        let searchUnreadableEntries: Int
        let searchIndexComplete: Bool
        let searchCacheByteCount: Int64
        let parsedContactCollections: Int
        let failedContactCollections: Int
        let parsedContacts: Int
        let contactsMissingNames: Int
        let contactsWithEmail: Int
        let contactsWithPhone: Int
        let contactsWithPostalAddress: Int
        let contactDistributionLists: Int
        let parsedCalendarCollections: Int
        let failedCalendarCollections: Int
        let parsedCalendarEvents: Int
        let calendarEventsMissingDates: Int
        let calendarEventsMissingTitles: Int
        let recurringCalendarEvents: Int
        let unsupportedRecurrencePatterns: Int
        let recurrenceExceptions: Int
        let cancelledCalendarEvents: Int
        let calendarEventsWithTimeZones: Int
        let privacy: PrivacyStatement
    }

    private struct PrivacyStatement: Encodable {
        let containsArchivePath: Bool
        let containsMessageContent: Bool
        let containsParticipantData: Bool
        let containsAttachmentNamesOrPayloads: Bool
        let containsContactOrCalendarContent: Bool
    }
}
