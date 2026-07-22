import Foundation

@main
enum ParserSmokeCheck {
    static func main() throws {
        let xml = """
        <emails><email>
          <OPFMessageCopySenderAddress>
            <emailAddress OPFContactEmailAddressAddress="jordan@example.com" OPFContactEmailAddressName="Jordan Lee" />
          </OPFMessageCopySenderAddress>
          <OPFMessageCopyToAddresses>
            <emailAddress OPFContactEmailAddressAddress="archive@example.com" OPFContactEmailAddressName="Archive Account" />
          </OPFMessageCopyToAddresses>
          <OPFMessageCopyCCAddresses>
            <emailAddress OPFContactEmailAddressAddress="cc@example.invalid" OPFContactEmailAddressName="Copied Person" />
          </OPFMessageCopyCCAddresses>
          <OPFMessageCopyBCCAddresses>
            <emailAddress OPFContactEmailAddressAddress="bcc@example.invalid" OPFContactEmailAddressName="Hidden Person" />
          </OPFMessageCopyBCCAddresses>
          <OPFMessageCopySubject>Project update</OPFMessageCopySubject>
          <OPFMessageCopyBody>The schedule is attached.</OPFMessageCopyBody>
          <OPFMessageCopyHTMLBody>&lt;p&gt;The &lt;strong&gt;schedule&lt;/strong&gt; is attached.&lt;/p&gt;</OPFMessageCopyHTMLBody>
          <OPFMessageCopyPreview>The schedule is attached.</OPFMessageCopyPreview>
          <OPFMessageCopyMessageID>message-123</OPFMessageCopyMessageID>
          <OPFMessageCopySentTime>2026-07-21T15:30:00Z</OPFMessageCopySentTime>
          <OPFMessageCopyReceivedTime>2026-07-21T15:31:00Z</OPFMessageCopyReceivedTime>
          <OPFMessageGetIsRead>0E0</OPFMessageGetIsRead>
          <OPFMessageCopyGetFlagStatus>1E0</OPFMessageCopyGetFlagStatus>
          <OPFMessageCopyAttachmentList>
            <messageAttachment
              OPFAttachmentName="Schedule.pdf"
              OPFAttachmentContentFileSize="2048"
              OPFAttachmentContentType="application/pdf"
              OPFAttachmentContentID="schedule@example.invalid"
              OPFAttachmentURL="Accounts/archive/com.microsoft.__Messages/Inbox/com.microsoft.__Attachments/schedule_0000" />
          </OPFMessageCopyAttachmentList>
        </email></emails>
        """

        guard let message = OLMMessageParser().parse(
            data: Data(xml.utf8),
            entryPath: "Accounts/archive/com.microsoft.__Messages/Inbox/message_00001.xml",
            folderID: "archive::Inbox"
        ) else {
            throw CheckFailure("Parser rejected valid OLM XML")
        }

        try require(message.id == "message-123", "message identifier")
        try require(message.subject == "Project update", "subject")
        try require(message.sender.address == "jordan@example.com", "sender")
        try require(message.recipients.map(\.address) == ["archive@example.com"], "recipients")
        try require(message.ccRecipients.map(\.address) == ["cc@example.invalid"], "CC recipients")
        try require(message.bccRecipients.map(\.address) == ["bcc@example.invalid"], "BCC recipients")
        try require(message.body == "The schedule is attached.", "body")
        try require(message.htmlBody?.contains("<strong>") == true, "HTML body")
        try require(message.messageID == "message-123", "stored message identifier")
        try require(message.receivedAt?.timeIntervalSince(message.sentAt) == 60, "received date")
        try require(!message.isRead, "read state")
        try require(message.isFlagged, "flag state")
        try require(message.attachments.first?.filename == "Schedule.pdf", "attachment name")
        try require(message.attachments.first?.byteCount == 2_048, "attachment size")
        try require(message.attachments.first?.contentID == "schedule@example.invalid", "attachment content ID")
        try require(message.attachments.first?.archiveEntryPath?.hasSuffix("schedule_0000") == true, "attachment URL")

        let truncatedXML = """
        <emails><email>
          <OPFMessageCopySubject>Recoverable subject</OPFMessageCopySubject>
          <OPFMessageCopyBody>Incomplete body
        """
        switch OLMMessageParser().parseOutcome(
            data: Data(truncatedXML.utf8),
            entryPath: "synthetic/recovered.xml",
            folderID: "synthetic::Inbox"
        ) {
        case .recovered(let recovered):
            try require(recovered.subject == "Recoverable subject", "recovered malformed XML metadata")
        default:
            throw CheckFailure("Parser did not recover fields preceding truncated XML")
        }

        switch OLMMessageParser().parseOutcome(
            data: Data("<not-a-message>broken".utf8),
            entryPath: "synthetic/unrecoverable.xml",
            folderID: "synthetic::Inbox"
        ) {
        case .failed: break
        default: throw CheckFailure("Parser accepted malformed XML without OLM message fields")
        }

        print("Parser and malformed-XML recovery smoke checks passed")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ field: String) throws {
        guard condition() else { throw CheckFailure("Incorrect \(field)") }
    }
}

private struct CheckFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
