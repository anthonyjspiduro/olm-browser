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
            isRead: true,
            isFlagged: false,
            attachments: []
        )

        try index.beginBatch()
        try index.insert(message, entryPath: "message_1.xml")
        try index.commitBatch(nextOffset: 1, complete: true)
        let results = try index.searchPaths(matching: "lighthouse budget", limit: 10)
        guard results == ["message_1.xml"] else {
            throw CheckFailure("FTS5 did not return the indexed message")
        }
        print("Search index smoke check passed")
    }
}

private struct CheckFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
