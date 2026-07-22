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
            ccRecipients: [MailParticipant(name: "Casey Copy", address: "cc@example.invalid")],
            bccRecipients: [MailParticipant(name: "Blake Hidden", address: "bcc@example.invalid")],
            messageID: "search-message@example.invalid",
            sentAt: Date(),
            receivedAt: nil,
            preview: "Budget review",
            body: "The approved lighthouse budget is ready.",
            htmlBody: nil,
            isRead: true,
            isFlagged: false,
            attachments: []
        )
        let olderUnreadMessage = MessageSummary(
            id: "older-message",
            folderID: "account::Inbox",
            subject: "Older synthetic message",
            sender: sender,
            recipients: [],
            ccRecipients: [],
            bccRecipients: [],
            messageID: "older-message@example.invalid",
            sentAt: message.sentAt.addingTimeInterval(-3_600),
            receivedAt: nil,
            preview: "Older preview",
            body: "Older body",
            htmlBody: nil,
            isRead: false,
            isFlagged: false,
            attachments: []
        )

        try index.beginBatch()
        try index.insert(message, entryPath: "message_1.xml")
        try index.insert(olderUnreadMessage, entryPath: "message_2.xml")
        try index.commitBatch(nextOffset: 2, complete: true)
        let results = try index.searchPaths(
            matching: "lighthouse budget from:jordan after:2020-01-01",
            folderID: "account::Inbox", offset: 0, limit: 10, sort: .relevance
        )
        guard results.paths == ["message_1.xml"], results.totalCount == 1 else {
            throw CheckFailure("FTS5 did not return the indexed message")
        }
        guard let lightweight = results.records.first?.messageSummary(),
              !lightweight.isFullyLoaded,
              lightweight.sourceEntryPath == "message_1.xml",
              lightweight.subject == message.subject else {
            throw CheckFailure("Indexed result did not produce a lightweight message row")
        }
        let copied = try index.searchPaths(
            matching: "cc:cc@example.invalid bcc:bcc@example.invalid",
            folderID: nil, offset: 0, limit: 10, sort: .relevance
        )
        guard copied.paths == ["message_1.xml"], copied.totalCount == 1 else {
            throw CheckFailure("CC/BCC filters did not return the indexed message")
        }
        let folderPage = try index.folderPagePaths(
            folderID: "account::Inbox", offset: 0, limit: 10
        )
        guard folderPage?.paths == ["message_1.xml", "message_2.xml"] else {
            throw CheckFailure("Folder paging was not globally chronological")
        }
        guard try index.unreadCountsByFolder()?["account::Inbox"] == 1 else {
            throw CheckFailure("Unread folder total was not accurate")
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
