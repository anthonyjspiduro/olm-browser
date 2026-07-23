import Foundation

@main
enum DiagnosticReportSmokeCheck {
    static func main() throws {
        let privateMarker = "private-sentinel-never-export"
        let participant = MailParticipant(name: privateMarker, address: "\(privateMarker)@example.invalid")
        let message = MessageSummary(
            id: privateMarker,
            folderID: privateMarker,
            subject: privateMarker,
            sender: participant,
            recipients: [participant],
            ccRecipients: [participant],
            bccRecipients: [participant],
            messageID: privateMarker,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            receivedAt: Date(timeIntervalSince1970: 1_700_000_060),
            preview: privateMarker,
            body: privateMarker,
            htmlBody: "<p>\(privateMarker)</p>",
            isRead: false,
            isFlagged: true,
            attachments: [AttachmentSummary(
                id: privateMarker,
                filename: privateMarker,
                byteCount: 42,
                contentType: "application/octet-stream"
            )]
        )
        let snapshot = ArchiveSnapshot(
            identity: ArchiveIdentity(
                url: URL(fileURLWithPath: "/private/\(privateMarker).olm"),
                displayName: "\(privateMarker).olm",
                size: 9_876_543,
                isPreviewData: false
            ),
            accounts: [MailAccount(id: privateMarker, displayName: privateMarker, address: participant.address)],
            folders: [MailFolder(
                id: privateMarker,
                accountID: privateMarker,
                parentID: nil,
                name: privateMarker,
                kind: .inbox,
                messageCount: 123,
                unreadCount: 7
            )],
            contactSources: [],
            calendarSources: [],
            messages: [message]
        )
        let status = ArchiveOperationalStatus(
            archiveEntries: 456,
            messageEntries: 123,
            attachmentEntries: 89,
            duplicateEntryPaths: 3,
            failedMessageEntries: 2,
            recoveredMalformedMessageEntries: 1,
            checksumFailureEntries: 4,
            unsupportedCompressionEntries: 5,
            cacheByteCount: 4_096,
            itemDiagnostics: ArchiveItemDiagnosticSummary(
                parsedContactCollections: 2, failedContactCollections: 1,
                parsedContacts: 40, contactsMissingNames: 2, contactsWithEmail: 32,
                contactsWithPhone: 21, contactsWithPostalAddress: 18,
                contactDistributionLists: 3, parsedCalendarCollections: 4,
                failedCalendarCollections: 1, parsedCalendarEvents: 500,
                calendarEventsMissingDates: 2, calendarEventsMissingTitles: 3,
                recurringCalendarEvents: 44, unsupportedRecurrencePatterns: 5,
                recurrenceExceptions: 7, cancelledCalendarEvents: 8,
                calendarEventsWithTimeZones: 450
            )
        )
        let progress = IndexProgress(indexed: 120, total: 123, isComplete: false, failed: 2)
        let data = try DiagnosticReportExporter.data(
            snapshot: snapshot,
            status: status,
            indexProgress: progress,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let text = String(decoding: data, as: UTF8.self)
        try require(!text.contains(privateMarker), "report excludes private identifiers and content")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        try require(object?["schemaVersion"] as? Int == 3, "schema version")
        try require(object?["archiveByteCount"] as? Int == 9_876_543, "archive size")
        try require(object?["messageEntries"] as? Int == 123, "message count")
        try require(object?["searchIndexedEntries"] as? Int == 120, "index progress")
        try require(object?["recoveredMalformedMessageEntries"] as? Int == 1, "recovered XML count")
        try require(object?["checksumFailureEntries"] as? Int == 4, "CRC failure count")
        try require(object?["unsupportedCompressionEntries"] as? Int == 5, "compression diagnostic count")
        try require(object?["parsedContacts"] as? Int == 40, "parsed contact count")
        try require(object?["contactDistributionLists"] as? Int == 3, "distribution-list count")
        try require(object?["parsedCalendarEvents"] as? Int == 500, "parsed calendar count")
        try require(object?["unsupportedRecurrencePatterns"] as? Int == 5, "recurrence diagnostic count")
        let privacy = object?["privacy"] as? [String: Any]
        try require(privacy?.values.allSatisfy { ($0 as? Bool) == false } == true, "privacy declaration")
        print("Privacy-preserving diagnostic report smoke check passed")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        guard condition() else { throw Failure("Failed: \(description)") }
    }
}

private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
