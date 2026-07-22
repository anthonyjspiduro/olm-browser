import Foundation

/// Design-milestone implementation. It validates the selected URL and returns
/// representative, explicitly labeled content without reading private messages.
struct PreviewArchiveReader: OLMArchiveReading {
    func openArchive(at url: URL) throws -> ArchiveSnapshot {
        let filename = url.lastPathComponent.lowercased()
        guard filename.hasSuffix(".olm") || filename.hasSuffix(".olm copy") else {
            throw ArchiveReaderError.unsupportedFile
        }

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isReadableKey])
        guard values?.isReadable != false else {
            throw ArchiveReaderError.unreadableArchive
        }

        let identity = ArchiveIdentity(
            url: url,
            displayName: url.lastPathComponent,
            size: Int64(values?.fileSize ?? 0),
            isPreviewData: true
        )

        let account = MailAccount(
            id: "preview-account",
            displayName: "Archive Account",
            address: "account@example.com"
        )

        let inbox = MailFolder(
            id: "preview-inbox",
            accountID: account.id,
            parentID: nil,
            name: "Inbox",
            kind: .inbox,
            messageCount: 12_842,
            unreadCount: 38
        )
        let sent = MailFolder(
            id: "preview-sent",
            accountID: account.id,
            parentID: nil,
            name: "Sent Items",
            kind: .sent,
            messageCount: 8_216,
            unreadCount: 0
        )
        let projects = MailFolder(
            id: "preview-projects",
            accountID: account.id,
            parentID: nil,
            name: "Client Projects",
            kind: .custom,
            messageCount: 3_104,
            unreadCount: 5
        )

        let sender = MailParticipant(name: "Jordan Lee", address: "jordan@example.com")
        let recipient = MailParticipant(name: "Archive Account", address: account.address)

        let messages = [
            MessageSummary(
                id: "preview-message-1",
                folderID: inbox.id,
                subject: "Final timeline and next steps",
                sender: sender,
                recipients: [recipient],
                ccRecipients: [],
                bccRecipients: [],
                messageID: "preview-message-1@example.invalid",
                sentAt: Date().addingTimeInterval(-3_600),
                receivedAt: Date().addingTimeInterval(-3_540),
                preview: "Here is the revised timeline we discussed, including the remaining review milestones…",
                body: "Hi,\n\nHere is the revised timeline we discussed, including the remaining review milestones. Please review the attached schedule before Thursday.\n\nThanks,\nJordan",
                htmlBody: "<p>Hi,</p><p>Here is the <strong>revised timeline</strong> we discussed. Please review the attached schedule before Thursday.</p><p>Thanks,<br>Jordan</p>",
                isRead: false,
                isFlagged: true,
                attachments: [
                    AttachmentSummary(
                        id: "preview-attachment-1",
                        filename: "Project Schedule.pdf",
                        byteCount: 1_842_320,
                        contentType: "application/pdf"
                    )
                ]
            ),
            MessageSummary(
                id: "preview-message-2",
                folderID: inbox.id,
                subject: "Re: Budget approval",
                sender: MailParticipant(name: "Morgan Chen", address: "morgan@example.com"),
                recipients: [recipient],
                ccRecipients: [],
                bccRecipients: [],
                messageID: "preview-message-2@example.invalid",
                sentAt: Date().addingTimeInterval(-86_400),
                receivedAt: Date().addingTimeInterval(-86_340),
                preview: "Approved. Please keep the final amount within the range noted below…",
                body: "Approved. Please keep the final amount within the range noted below and send the completed estimate to the team.",
                htmlBody: nil,
                isRead: true,
                isFlagged: false,
                attachments: []
            ),
            MessageSummary(
                id: "preview-message-3",
                folderID: sent.id,
                subject: "Status recap",
                sender: recipient,
                recipients: [sender],
                ccRecipients: [],
                bccRecipients: [],
                messageID: "preview-message-3@example.invalid",
                sentAt: Date().addingTimeInterval(-172_800),
                receivedAt: Date().addingTimeInterval(-172_740),
                preview: "The review is complete and the deliverables are ready for the next stage…",
                body: "The review is complete and the deliverables are ready for the next stage. I included a concise status recap below.",
                htmlBody: nil,
                isRead: true,
                isFlagged: false,
                attachments: []
            ),
            MessageSummary(
                id: "preview-message-4",
                folderID: projects.id,
                subject: "Creative review notes",
                sender: sender,
                recipients: [recipient],
                ccRecipients: [],
                bccRecipients: [],
                messageID: "preview-message-4@example.invalid",
                sentAt: Date().addingTimeInterval(-259_200),
                receivedAt: Date().addingTimeInterval(-259_140),
                preview: "The client consolidated their feedback into three requested changes…",
                body: "The client consolidated their feedback into three requested changes. The notes here are representative design data only.",
                htmlBody: nil,
                isRead: false,
                isFlagged: false,
                attachments: []
            )
        ]

        return ArchiveSnapshot(
            identity: identity,
            accounts: [account],
            folders: [inbox, sent, projects],
            messages: messages
        )
    }

    func loadMessages(in folderID: MailFolder.ID, offset: Int, limit: Int) throws -> MessagePage {
        MessagePage(messages: [], nextOffset: 0, totalCount: 0)
    }

    func buildSearchIndex(progress: @escaping @Sendable (IndexProgress) -> Void) throws {
        progress(IndexProgress(indexed: 0, total: 0, isComplete: true))
    }

    func searchMessages(matching query: String, folderID: MailFolder.ID?, offset: Int, limit: Int, sort: SearchSort) throws -> MessagePage {
        MessagePage(messages: [], nextOffset: 0, totalCount: 0)
    }

    func loadMessageDetails(for message: MessageSummary) throws -> MessageSummary { message }

    func attachmentData(for attachment: AttachmentSummary) throws -> Data {
        throw ArchiveReaderError.unreadableArchive
    }

    func operationalStatus() -> ArchiveOperationalStatus {
        ArchiveOperationalStatus(archiveEntries: 0, messageEntries: 0, attachmentEntries: 0, duplicateEntryPaths: 0, failedMessageEntries: 0, recoveredMalformedMessageEntries: 0, checksumFailureEntries: 0, unsupportedCompressionEntries: 0, cacheByteCount: 0)
    }
    func folderUnreadCounts() -> [MailFolder.ID: Int]? {
        ["preview-inbox": 38, "preview-sent": 0, "preview-projects": 5]
    }
    func resetSearchIndex() throws {}
    func deleteSearchCache() throws {}
}
