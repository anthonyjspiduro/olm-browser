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
                sentAt: Date().addingTimeInterval(-3_600),
                preview: "Here is the revised timeline we discussed, including the remaining review milestones…",
                body: "Hi,\n\nHere is the revised timeline we discussed, including the remaining review milestones. Please review the attached schedule before Thursday.\n\nThanks,\nJordan",
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
                sentAt: Date().addingTimeInterval(-86_400),
                preview: "Approved. Please keep the final amount within the range noted below…",
                body: "Approved. Please keep the final amount within the range noted below and send the completed estimate to the team.",
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
                sentAt: Date().addingTimeInterval(-172_800),
                preview: "The review is complete and the deliverables are ready for the next stage…",
                body: "The review is complete and the deliverables are ready for the next stage. I included a concise status recap below.",
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
                sentAt: Date().addingTimeInterval(-259_200),
                preview: "The client consolidated their feedback into three requested changes…",
                body: "The client consolidated their feedback into three requested changes. The notes here are representative design data only.",
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
}
