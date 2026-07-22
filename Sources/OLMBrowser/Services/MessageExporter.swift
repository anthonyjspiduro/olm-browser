import Foundation
import CoreGraphics
import CoreText

enum MessageExportFormat: String, CaseIterable, Identifiable {
    case eml
    case plainText = "txt"
    case json
    case pdf
    case csv

    var id: String { rawValue }
    var label: String {
        switch self {
        case .eml: "Email (.eml)"
        case .plainText: "Plain Text (.txt)"
        case .json: "JSON (.json)"
        case .pdf: "PDF (.pdf)"
        case .csv: "CSV (.csv)"
        }
    }
}

enum MessageExporter {
    static func data(for message: MessageSummary, format: MessageExportFormat, reader: any OLMArchiveReading) throws -> Data {
        switch format {
        case .plainText: Data(plainText(message).utf8)
        case .json: try json(message)
        case .eml: try eml(message, reader: reader)
        case .pdf: try pdf(message)
        case .csv: csvData(for: [message])
        }
    }

    static func csvData(for messages: [MessageSummary]) -> Data {
        let header = [
            "message_id", "folder_id", "subject", "from", "to", "cc", "bcc",
            "sent_at", "received_at", "is_read", "is_flagged", "attachment_count", "body"
        ]
        let formatter = ISO8601DateFormatter()
        let rows = messages.map { message in
            [
                message.messageID ?? message.id,
                message.folderID,
                message.subject,
                participant(message.sender),
                message.recipients.map(participant).joined(separator: "; "),
                message.ccRecipients.map(participant).joined(separator: "; "),
                message.bccRecipients.map(participant).joined(separator: "; "),
                formatter.string(from: message.sentAt),
                message.receivedAt.map(formatter.string) ?? "",
                message.isRead ? "true" : "false",
                message.isFlagged ? "true" : "false",
                String(message.attachments.count),
                message.body
            ].map(csvField).joined(separator: ",")
        }
        return Data(([header.joined(separator: ",")] + rows).joined(separator: "\r\n").appending("\r\n").utf8)
    }

    private static func plainText(_ message: MessageSummary) -> String {
        """
        Subject: \(message.subject)
        From: \(participant(message.sender))
        To: \(message.recipients.map(participant).joined(separator: ", "))
        CC: \(message.ccRecipients.map(participant).joined(separator: ", "))
        BCC: \(message.bccRecipients.map(participant).joined(separator: ", "))
        Message-ID: \(message.messageID ?? "")
        Date: \(message.sentAt.formatted(date: .long, time: .complete))
        Received: \(message.receivedAt?.formatted(date: .long, time: .complete) ?? "")
        Status: \(message.isRead ? "Read" : "Unread")\(message.isFlagged ? ", Flagged" : "")

        \(message.body)
        """
    }

    private static func json(_ message: MessageSummary) throws -> Data {
        let object: [String: Any] = [
            "id": message.id,
            "folderID": message.folderID,
            "subject": message.subject,
            "from": ["name": message.sender.name, "address": message.sender.address],
            "to": message.recipients.map { ["name": $0.name, "address": $0.address] },
            "cc": message.ccRecipients.map { ["name": $0.name, "address": $0.address] },
            "bcc": message.bccRecipients.map { ["name": $0.name, "address": $0.address] },
            "messageID": message.messageID ?? NSNull(),
            "sentAt": ISO8601DateFormatter().string(from: message.sentAt),
            "receivedAt": message.receivedAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
            "body": message.body,
            "htmlBody": message.htmlBody ?? NSNull(),
            "isRead": message.isRead,
            "isFlagged": message.isFlagged,
            "attachments": message.attachments.map {
                ["filename": $0.filename, "contentType": $0.contentType, "byteCount": $0.byteCount] as [String: Any]
            }
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func eml(_ message: MessageSummary, reader: any OLMArchiveReading) throws -> Data {
        let boundary = "OLMBrowser-\(UUID().uuidString)"
        var output = "Date: \(rfc822Date(message.sentAt))\r\n"
        output += "From: \(header(participant(message.sender)))\r\n"
        output += "To: \(header(message.recipients.map(participant).joined(separator: ", ")))\r\n"
        if !message.ccRecipients.isEmpty {
            output += "Cc: \(header(message.ccRecipients.map(participant).joined(separator: ", ")))\r\n"
        }
        if !message.bccRecipients.isEmpty {
            output += "Bcc: \(header(message.bccRecipients.map(participant).joined(separator: ", ")))\r\n"
        }
        output += "Subject: \(encodedHeader(message.subject))\r\n"
        if let messageID = message.messageID {
            output += "Message-ID: \(header(messageID))\r\n"
        }
        output += "MIME-Version: 1.0\r\n"
        output += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n"
        output += "--\(boundary)\r\n"
        if let html = message.htmlBody {
            let alternative = "OLMBrowser-Alternative-\(UUID().uuidString)"
            output += "Content-Type: multipart/alternative; boundary=\"\(alternative)\"\r\n\r\n"
            output += "--\(alternative)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            output += base64Lines(Data(message.body.utf8)) + "\r\n"
            output += "--\(alternative)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            output += base64Lines(Data(html.utf8)) + "\r\n--\(alternative)--\r\n"
        } else {
            output += "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            output += base64Lines(Data(message.body.utf8)) + "\r\n"
        }
        for attachment in message.attachments where attachment.isAvailable {
            let data = try reader.attachmentData(for: attachment)
            output += "--\(boundary)\r\nContent-Type: \(safeMIME(attachment.contentType)); name=\"\(quotedFilename(attachment.filename))\"\r\n"
            output += "Content-Disposition: attachment; filename=\"\(quotedFilename(attachment.filename))\"\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            output += base64Lines(data) + "\r\n"
        }
        output += "--\(boundary)--\r\n"
        return Data(output.utf8)
    }

    private static func pdf(_ message: MessageSummary) throws -> Data {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else {
            throw MessageExportError.pdfCreationFailed
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw MessageExportError.pdfCreationFailed
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        let attributed = NSAttributedString(
            string: plainText(message),
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var location = 0
        repeat {
            context.beginPDFPage(nil)
            let path = CGPath(rect: CGRect(x: 54, y: 54, width: 504, height: 684), transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: location, length: attributed.length - location),
                path,
                nil
            )
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            location += visible.length
            context.endPDFPage()
            if visible.length == 0 { break }
        } while location < attributed.length
        context.closePDF()
        guard output.length > 0 else { throw MessageExportError.pdfCreationFailed }
        return output as Data
    }

    private static func participant(_ value: MailParticipant) -> String {
        value.displayLabel
    }

    private static func header(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    private static func csvField(_ value: String) -> String {
        let trimmed = value.drop(while: { $0.isWhitespace })
        let spreadsheetSafe = trimmed.first.map({ "=+-@".contains($0) }) == true
            ? "'" + value
            : value
        return "\"\(spreadsheetSafe.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func encodedHeader(_ value: String) -> String {
        let clean = header(value)
        return clean.unicodeScalars.allSatisfy(\.isASCII)
            ? clean
            : "=?UTF-8?B?\(Data(clean.utf8).base64EncodedString())?="
    }

    private static func quotedFilename(_ value: String) -> String {
        AttachmentFileStore.safeFilename(value).replacingOccurrences(of: "\\", with: "_").replacingOccurrences(of: "\"", with: "'")
    }

    private static func safeMIME(_ value: String) -> String {
        let clean = value.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || "/+.-".contains($0)) }
        return clean.contains("/") ? clean : "application/octet-stream"
    }

    private static func base64Lines(_ data: Data) -> String {
        let encoded = data.base64EncodedString()
        return stride(from: 0, to: encoded.count, by: 76).map { start in
            let from = encoded.index(encoded.startIndex, offsetBy: start)
            let to = encoded.index(from, offsetBy: min(76, encoded.count - start))
            return String(encoded[from..<to])
        }.joined(separator: "\r\n")
    }

    private static func rfc822Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}

private enum MessageExportError: LocalizedError {
    case pdfCreationFailed

    var errorDescription: String? { "The PDF could not be created." }
}
