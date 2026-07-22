import Foundation

@main
enum SearchSmokeCheck {
    static func main() throws {
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("olm-search-smoke-\(UUID().uuidString).olm")
        let index = try OLMSearchIndex(archiveURL: archiveURL, fileSize: 123, modifiedAt: Date())
        let sender = MailParticipant(name: "Jordan Lee", address: "jordan@example.com")
        let message = MessageSummary(
            id: "search-message",
            folderID: "account::Inbox",
            subject: "Quarterly lighthouse project",
            sender: sender,
            recipients: [],
            sentAt: Date(),
            preview: "Budget review",
            body: "The approved lighthouse budget is ready.",
            htmlBody: nil,
            isRead: true,
            isFlagged: false,
            attachments: []
        )

        try index.beginBatch()
        try index.insert(message, entryPath: "message_1.xml")
        try index.commitBatch(nextOffset: 1, complete: true)
        let results = try index.searchPaths(
            matching: "lighthouse budget from:jordan after:2020-01-01",
            folderID: "account::Inbox", offset: 0, limit: 10, sort: .relevance
        )
        guard results.paths == ["message_1.xml"], results.totalCount == 1 else {
            throw CheckFailure("FTS5 did not return the indexed message")
        }
        let filtered = try index.searchPaths(
            matching: "has:attachment", folderID: nil, offset: 0, limit: 10, sort: .newest
        )
        guard filtered.paths.isEmpty else { throw CheckFailure("Attachment filter returned a message without attachments") }
        print("Search index smoke check passed")
    }
}

private struct CheckFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
