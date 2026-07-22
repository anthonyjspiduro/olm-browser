import Foundation

enum DiagnosticReportExporter {
    static func data(
        snapshot: ArchiveSnapshot,
        status: ArchiveOperationalStatus,
        indexProgress: IndexProgress,
        generatedAt: Date = Date()
    ) throws -> Data {
        let report = Report(
            schemaVersion: 2,
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
            privacy: PrivacyStatement(
                containsArchivePath: false,
                containsMessageContent: false,
                containsParticipantData: false,
                containsAttachmentNamesOrPayloads: false
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
        let privacy: PrivacyStatement
    }

    private struct PrivacyStatement: Encodable {
        let containsArchivePath: Bool
        let containsMessageContent: Bool
        let containsParticipantData: Bool
        let containsAttachmentNamesOrPayloads: Bool
    }
}
