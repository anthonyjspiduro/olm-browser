import Foundation

@main
enum ArchiveSmokeCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw CheckFailure("Usage: archive-check /path/to/archive.olm")
        }

        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let snapshot = try NativeOLMArchiveReader().openArchive(at: url)
        guard let folder = snapshot.folders.first(where: { $0.messageCount > 150 }) else {
            throw CheckFailure("No folder large enough to test paging")
        }
        let firstPage = try NativeOLMArchiveReaderCheck.shared.loadFirstPage(
            readerURL: url,
            folderID: folder.id
        )
        let status = readerStatus(readerURL: url)
        let report = try DiagnosticReportExporter.data(
            snapshot: snapshot,
            status: status,
            indexProgress: IndexProgress(
                indexed: 0,
                total: snapshot.folders.reduce(0) { $0 + $1.messageCount },
                isComplete: false
            )
        )
        let reportText = String(decoding: report, as: UTF8.self)
        guard !reportText.contains(snapshot.identity.url.path),
              !reportText.contains(snapshot.identity.displayName) else {
            throw CheckFailure("Diagnostic report exposed archive identity")
        }
        print("Accounts: \(snapshot.accounts.count)")
        print("Folders: \(snapshot.folders.count)")
        print("Cataloged messages: \(snapshot.folders.reduce(0) { $0 + $1.messageCount })")
        print("Paging check: \(firstPage) unique messages across two pages")
        print("Attachment payload entries: \(status.attachmentEntries)")
        print("Duplicate ZIP paths: \(status.duplicateEntryPaths)")
        print("Aggregate diagnostic report privacy check passed")
    }

    private static func readerStatus(readerURL: URL) -> ArchiveOperationalStatus {
        let reader = NativeOLMArchiveReader()
        _ = try? reader.openArchive(at: readerURL)
        return reader.operationalStatus()
    }
}

private final class NativeOLMArchiveReaderCheck {
    static let shared = NativeOLMArchiveReaderCheck()

    func loadFirstPage(readerURL: URL, folderID: MailFolder.ID) throws -> Int {
        let reader = NativeOLMArchiveReader()
        _ = try reader.openArchive(at: readerURL)
        let first = try reader.loadMessages(in: folderID, offset: 0, limit: 100)
        let second = try reader.loadMessages(in: folderID, offset: first.nextOffset, limit: 100)
        let combined = first.messages + second.messages
        let ids = Set(combined.map(\.id))
        guard first.nextOffset == 100, second.nextOffset == 200, ids.count == 200 else {
            throw CheckFailure("Paging returned duplicate or incorrect offsets")
        }
        print("HTML messages in paging sample: \(combined.filter { $0.htmlBody != nil }.count)")
        print("Messages with CC in paging sample: \(combined.filter { !$0.ccRecipients.isEmpty }.count)")
        print("Messages with BCC in paging sample: \(combined.filter { !$0.bccRecipients.isEmpty }.count)")
        let attachments = combined.flatMap(\.attachments)
        let available = attachments.filter(\.isAvailable)
        let missing = attachments.filter { $0.diagnostic == .missingPayload }.count
        let malformed = attachments.filter { $0.diagnostic == .malformedReference }.count
        let duplicate = attachments.filter { $0.diagnostic == .duplicatePayload }.count
        let oversized = attachments.filter { if case .oversized = $0.diagnostic { true } else { false } }.count
        if let attachment = available.first {
            let data = try reader.attachmentData(for: attachment)
            guard Int64(data.count) == attachment.byteCount else {
                throw CheckFailure("Resolved attachment size did not match its ZIP entry")
            }
        }
        print("Paging attachment diagnostics: total=\(attachments.count), available=\(available.count), missing=\(missing), malformed=\(malformed), duplicate=\(duplicate), oversized=\(oversized)")
        return ids.count
    }
}

private struct CheckFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
