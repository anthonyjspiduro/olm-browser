import Foundation

final class OLMMessageParser: NSObject, XMLParserDelegate {
    enum Outcome {
        case parsed(MessageSummary)
        case recovered(MessageSummary)
        case failed
    }

    private var elements: [String] = []
    private var text = ""
    private var subject = ""
    private var body = ""
    private var htmlBody = ""
    private var preview = ""
    private var messageID = ""
    private var sentDateText = ""
    private var receivedDateText = ""
    private var sender: MailParticipant?
    private var recipients: [MailParticipant] = []
    private var ccRecipients: [MailParticipant] = []
    private var bccRecipients: [MailParticipant] = []
    private var isRead = true
    private var isFlagged = false
    private var attachments: [AttachmentSummary] = []
    private var sawMessageContainer = false
    private var recognizedFieldCount = 0

    func parse(data: Data, entryPath: String, folderID: String) -> MessageSummary? {
        switch parseOutcome(data: data, entryPath: entryPath, folderID: folderID) {
        case .parsed(let message), .recovered(let message): message
        case .failed: nil
        }
    }

    func parseOutcome(data: Data, entryPath: String, folderID: String) -> Outcome {
        reset()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        let parsedCompletely = parser.parse()
        guard parsedCompletely || (sawMessageContainer && recognizedFieldCount > 0) else {
            return .failed
        }

        let resolvedSender = sender ?? MailParticipant(name: "Unknown Sender", address: "")
        let parsedReceivedDate = Self.parseDate(receivedDateText)
        let resolvedDate = Self.parseDate(sentDateText)
            ?? parsedReceivedDate
            ?? .distantPast
        let resolvedBody = body.isEmpty ? preview : body
        let resolvedPreview = preview.isEmpty
            ? String(resolvedBody.prefix(240)).replacingOccurrences(of: "\n", with: " ")
            : preview

        let message = MessageSummary(
            id: messageID.isEmpty ? entryPath : messageID,
            folderID: folderID,
            subject: subject.isEmpty ? "(No Subject)" : subject,
            sender: resolvedSender,
            recipients: recipients,
            ccRecipients: ccRecipients,
            bccRecipients: bccRecipients,
            messageID: messageID.isEmpty ? nil : messageID,
            sentAt: resolvedDate,
            receivedAt: parsedReceivedDate,
            preview: resolvedPreview,
            body: resolvedBody,
            htmlBody: htmlBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : htmlBody,
            isRead: isRead,
            isFlagged: isFlagged,
            attachments: attachments,
            sourceEntryPath: entryPath
        )
        return parsedCompletely ? .parsed(message) : .recovered(message)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        elements.append(elementName)
        text = ""

        if elementName == "email" { sawMessageContainer = true }

        if elementName == "emailAddress" {
            recognizedFieldCount += 1
            let participant = MailParticipant(
                name: attributeDict["OPFContactEmailAddressName"] ?? "",
                address: attributeDict["OPFContactEmailAddressAddress"] ?? ""
            )
            let container = elements.dropLast().last ?? ""
            if container == "OPFMessageCopySenderAddress" {
                sender = participant
            } else if container == "OPFMessageCopyToAddresses" {
                recipients.append(participant)
            } else if container == "OPFMessageCopyCCAddresses" {
                ccRecipients.append(participant)
            } else if container == "OPFMessageCopyBCCAddresses" {
                bccRecipients.append(participant)
            } else if container == "OPFMessageCopyFromAddresses", sender == nil {
                sender = participant
            }
        } else if elementName == "messageAttachment" {
            recognizedFieldCount += 1
            let index = attachments.count
            let size = Int64(attributeDict["OPFAttachmentContentFileSize"] ?? "") ?? 0
            let filename = attributeDict["OPFAttachmentName"]
                ?? attributeDict["OPFAttachmentContentID"]
                ?? "Attachment \(index + 1)"
            attachments.append(AttachmentSummary(
                id: "\(index)-\(filename)",
                filename: filename,
                byteCount: size,
                contentType: attributeDict["OPFAttachmentContentType"] ?? "application/octet-stream",
                contentID: attributeDict["OPFAttachmentContentID"],
                archiveEntryPath: attributeDict["OPFAttachmentURL"]
            ))
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "OPFMessageCopySubject": subject = text; recognizedFieldCount += 1
        case "OPFMessageCopyBody": body = text; recognizedFieldCount += 1
        case "OPFMessageCopyHTMLBody": htmlBody = text; recognizedFieldCount += 1
        case "OPFMessageCopyPreview": preview = text; recognizedFieldCount += 1
        case "OPFMessageCopyMessageID": messageID = text; recognizedFieldCount += 1
        case "OPFMessageCopySentTime": sentDateText = text; recognizedFieldCount += 1
        case "OPFMessageCopyReceivedTime": receivedDateText = text; recognizedFieldCount += 1
        case "OPFMessageGetIsRead": isRead = Self.parseBoolean(text, defaultValue: true); recognizedFieldCount += 1
        case "OPFMessageCopyGetFlagStatus":
            isFlagged = Self.parseBoolean(text, defaultValue: false)
            recognizedFieldCount += 1
        default: break
        }
        if elements.last == elementName { elements.removeLast() }
        text = ""
    }

    private func reset() {
        elements = []
        text = ""
        subject = ""
        body = ""
        htmlBody = ""
        preview = ""
        messageID = ""
        sentDateText = ""
        receivedDateText = ""
        sender = nil
        recipients = []
        ccRecipients = []
        bccRecipients = []
        isRead = true
        isFlagged = false
        attachments = []
        sawMessageContainer = false
        recognizedFieldCount = 0
    }

    private static func parseBoolean(_ value: String, defaultValue: Bool) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default:
            if let numeric = Double(normalized) { return numeric != 0 }
            return defaultValue
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standardFormatter = ISO8601DateFormatter()
        if let date = fractionalFormatter.date(from: trimmed)
            ?? standardFormatter.date(from: trimmed) {
            return date
        }
        let legacyFormatter = DateFormatter()
        legacyFormatter.locale = Locale(identifier: "en_US_POSIX")
        legacyFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        legacyFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return legacyFormatter.date(from: trimmed)
    }
}
