import Foundation
import PDFKit

@main
enum ExportSmokeCheck {
    static func main() throws {
        let attachment = AttachmentSummary(
            id: "a1", filename: "../unsafe:name.txt", byteCount: 5,
            contentType: "text/plain", contentID: "inline@example.invalid", archiveEntryPath: "payload"
        )
        let message = MessageSummary(
            id: "m1", folderID: "account::Inbox", subject: "Synthetic subject",
            sender: MailParticipant(name: "Sender", address: "sender@example.invalid"),
            recipients: [MailParticipant(name: "Recipient", address: "recipient@example.invalid")],
            ccRecipients: [MailParticipant(name: "Copied", address: "cc@example.invalid")],
            bccRecipients: [MailParticipant(name: "Hidden", address: "bcc@example.invalid")],
            messageID: "synthetic-message@example.invalid",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            receivedAt: Date(timeIntervalSince1970: 1_700_000_060), preview: "Synthetic preview",
            body: "=Synthetic body", htmlBody: "<p>Synthetic body</p>", isRead: true,
            isFlagged: false, attachments: [attachment]
        )
        let reader = SyntheticReader()
        let text = try MessageExporter.data(for: message, format: .plainText, reader: reader)
        let json = try MessageExporter.data(for: message, format: .json, reader: reader)
        let eml = try MessageExporter.data(for: message, format: .eml, reader: reader)
        let pdf = try MessageExporter.data(for: message, format: .pdf, reader: reader)
        let csv = try MessageExporter.data(for: message, format: .csv, reader: reader)
        try require(String(data: text, encoding: .utf8)?.contains("Synthetic body") == true, "text export")
        let jsonObject = try JSONSerialization.jsonObject(with: json)
        try require(jsonObject is [String: Any], "JSON export")
        try require(String(data: eml, encoding: .utf8)?.contains("multipart/mixed") == true, "EML export")
        try require(String(data: text, encoding: .utf8)?.contains("CC: Copied <cc@example.invalid>") == true, "text CC export")
        try require((jsonObject as? [String: Any])?["bcc"] is [[String: String]], "JSON BCC export")
        try require(String(data: eml, encoding: .utf8)?.contains("Bcc: Hidden <bcc@example.invalid>") == true, "EML BCC export")
        try require(pdf.starts(with: Data("%PDF".utf8)), "PDF export")
        let pdfDocument = PDFDocument(data: pdf)
        try require(
            pdfDocument?.pageCount ?? 0 > 0
                && pdfDocument?.page(at: 0)?.string?.contains("Synthetic subject") == true,
            "readable paginated PDF"
        )
        try require(String(data: csv, encoding: .utf8)?.contains("\"Synthetic subject\"") == true, "CSV export")
        try require(String(data: csv, encoding: .utf8)?.contains("\"'=Synthetic body\"") == true, "CSV formula neutralization")
        let batchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("olm-message-batch-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: batchDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: batchDirectory) }
        let existing = batchDirectory.appendingPathComponent("0001 Synthetic subject.json")
        try Data("existing".utf8).write(to: existing)
        let batchCount = try MessageBatchExporter.exportFiles(
            [message, message], format: .json, to: batchDirectory, reader: reader
        )
        let batchFiles = try FileManager.default.contentsOfDirectory(atPath: batchDirectory.path)
        try require(batchCount == 2 && Set(batchFiles).count == 3, "bounded collision-safe batch export")
        let preserved = try Data(contentsOf: existing)
        try require(preserved == Data("existing".utf8), "batch export does not overwrite")
        try require(AttachmentFileStore.safeFilename(attachment.filename) == "unsafe-name.txt", "safe filename")
        print("Message and attachment export smoke check passed")
    }

    private static func require(_ value: @autoclosure () -> Bool, _ label: String) throws {
        guard value() else { throw Failure("Failed \(label)") }
    }
}

private struct SyntheticReader: OLMArchiveReading {
    func openArchive(at url: URL) throws -> ArchiveSnapshot { throw Failure("unused") }
    func loadMessages(in folderID: String, offset: Int, limit: Int) throws -> MessagePage { MessagePage(messages: [], nextOffset: 0, totalCount: 0) }
    func buildSearchIndex(progress: @escaping @Sendable (IndexProgress) -> Void) throws {}
    func searchMessages(matching query: String, folderID: String?, offset: Int, limit: Int, sort: SearchSort) throws -> MessagePage { MessagePage(messages: [], nextOffset: 0, totalCount: 0) }
    func loadMessageDetails(for message: MessageSummary) throws -> MessageSummary { message }
    func loadContacts(sourceID: ArchiveItemSource.ID?, matching query: String, offset: Int, limit: Int) throws -> ContactPage {
        ContactPage(records: [], nextOffset: 0, totalCount: 0)
    }
    func loadCalendarEvents(sourceID: ArchiveItemSource.ID?, matching query: String, offset: Int, limit: Int) throws -> CalendarEventPage {
        CalendarEventPage(records: [], nextOffset: 0, totalCount: 0)
    }
    func attachmentData(for attachment: AttachmentSummary) throws -> Data { Data("hello".utf8) }
    func operationalStatus() -> ArchiveOperationalStatus { ArchiveOperationalStatus(archiveEntries: 0, messageEntries: 0, attachmentEntries: 0, duplicateEntryPaths: 0, failedMessageEntries: 0, recoveredMalformedMessageEntries: 0, checksumFailureEntries: 0, unsupportedCompressionEntries: 0, cacheByteCount: 0) }
    func folderUnreadCounts() -> [String: Int]? { [:] }
    func resetSearchIndex() throws {}
    func deleteSearchCache() throws {}
}

private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
