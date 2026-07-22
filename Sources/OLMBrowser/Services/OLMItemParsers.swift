import Foundation

final class OLMContactParser: NSObject, XMLParserDelegate {
    private var sourceID = ""
    private var sourcePath = ""
    private var records: [ContactRecord] = []
    private var ordinal = 0
    private var inContact = false
    private var elements: [String] = []
    private var text = ""
    private var fields: [String: String] = [:]
    private var emails: [ContactEmailAddress] = []
    private var phones: [ContactPhoneNumber] = []

    func parse(data: Data, source: ArchiveItemSource) -> [ContactRecord] {
        reset(source: source)
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        return records
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        elements.append(elementName)
        text = ""
        if elementName == "contact" {
            inContact = true
            fields = [:]
            emails = []
            phones = []
        }
        if elementName == "contactEmailAddress" {
            let address = attributeDict["OPFContactEmailAddressAddress"] ?? ""
            let label = attributeDict["OPFContactEmailAddressType"]
                ?? attributeDict["OPFContactEmailAddressName"] ?? "Email"
            if !address.isEmpty { emails.append(.init(label: label, address: address)) }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inContact, elementName.hasPrefix("OPFContact"), !value.isEmpty {
            fields[elementName] = value
            if ["phone", "fax", "pager", "telex"].contains(where: { elementName.localizedCaseInsensitiveContains($0) }) {
                phones.append(.init(label: Self.readableLabel(elementName, removing: "OPFContactCopy"), number: value))
            }
        } else if inContact, elementName == "contactEmailAddress", !value.isEmpty,
                  !emails.contains(where: { $0.address == value }) {
            let mailbox = OLMItemMailboxParser.parse(value)
            emails.append(.init(label: "Email", address: mailbox.address))
        } else if elementName == "contact", inContact {
            appendContact()
            inContact = false
        }
        if elements.last == elementName { elements.removeLast() }
        text = ""
    }

    private func appendContact() {
        ordinal += 1
        let first = field("OPFContactCopyFirstName")
        let middle = field("OPFContactCopyMiddleName")
        let last = field("OPFContactCopyLastName")
        let composed = [first, middle, last].filter { !$0.isEmpty }.joined(separator: " ")
        let display = field("OPFContactCopyDisplayName")
        records.append(ContactRecord(
            id: "\(sourcePath)#contact-\(ordinal)", sourceID: sourceID,
            displayName: display.isEmpty ? (composed.isEmpty ? "Unnamed Contact" : composed) : display,
            firstName: first, middleName: middle, lastName: last,
            company: field("OPFContactCopyBusinessCompany"),
            jobTitle: field("OPFContactCopyBusinessTitle", "OPFContactCopyJobTitle"),
            emails: Self.unique(emails), phoneNumbers: Self.unique(phones),
            notes: field("OPFContactCopyNotesPlain", "OPFContactCopyNotes"),
            modifiedAt: OLMItemDateParser.parse(field("OPFContactCopyModDate"))
        ))
    }

    private func field(_ names: String...) -> String {
        for name in names where !(fields[name] ?? "").isEmpty { return fields[name] ?? "" }
        return ""
    }

    private func reset(source: ArchiveItemSource) {
        sourceID = source.id; sourcePath = source.entryPath; records = []; ordinal = 0
        inContact = false; elements = []; text = ""; fields = [:]; emails = []; phones = []
    }

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }
    private static func readableLabel(_ value: String, removing prefix: String) -> String {
        value.replacingOccurrences(of: prefix, with: "")
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
    }
}

final class OLMCalendarParser: NSObject, XMLParserDelegate {
    private var sourceID = ""
    private var sourcePath = ""
    private var records: [CalendarEventRecord] = []
    private var ordinal = 0
    private var inAppointment = false
    private var text = ""
    private var fields: [String: String] = [:]
    private var attendees: [CalendarAttendee] = []

    func parse(data: Data, source: ArchiveItemSource) -> [CalendarEventRecord] {
        sourceID = source.id; sourcePath = source.entryPath; records = []; ordinal = 0
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        return records
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        if elementName == "appointment" {
            inAppointment = true; fields = [:]; attendees = []
        }
        if inAppointment, elementName == "appointmentAttendee" {
            let address = attributeDict["OPFCalendarAttendeeAddress"]
                ?? attributeDict["OPFContactEmailAddressAddress"] ?? ""
            let name = attributeDict["OPFCalendarAttendeeName"]
                ?? attributeDict["OPFContactEmailAddressName"] ?? ""
            if !address.isEmpty || !name.isEmpty {
                attendees.append(.init(
                    name: name, address: address,
                    type: attributeDict["OPFCalendarAttendeeType"] ?? "",
                    status: attributeDict["OPFCalendarAttendeeStatus"] ?? "",
                    responseRequested: Self.boolean(attributeDict["OPFCalendarAttendeeResponseRequested"] ?? "")
                ))
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inAppointment, elementName.hasPrefix("OPF"), !value.isEmpty { fields[elementName] = value }
        if inAppointment, elementName == "appointmentAttendee", !value.isEmpty,
           !attendees.contains(where: { $0.address == value }) {
            let mailbox = OLMItemMailboxParser.parse(value)
            attendees.append(.init(name: mailbox.name, address: mailbox.address, type: "", status: "", responseRequested: false))
        }
        if elementName == "appointment", inAppointment { appendEvent(); inAppointment = false }
        text = ""
    }

    private func appendEvent() {
        ordinal += 1
        let start = OLMItemDateParser.parse(field("OPFCalendarEventCopyStartTime")) ?? .distantPast
        let end = OLMItemDateParser.parse(field("OPFCalendarEventCopyEndTime")) ?? start
        let recurring = boolean("OPFCalendarEventIsRecurring")
        let recurrence = recurring ? CalendarRecurrence(
            frequency: field("OPFRecurrencePatternType"),
            interval: Int(field("OPFRecurrencePatternInterval")) ?? 1,
            occurrenceCount: Int(field("OPFRecurrenceGetOccurenceCount")),
            endDate: OLMItemDateParser.parse(field("OPFRecurrenceCopyEndDate"))
        ) : nil
        let uuid = field("OPFCalendarEventCopyUUID")
        records.append(CalendarEventRecord(
            id: uuid.isEmpty ? "\(sourcePath)#appointment-\(ordinal)" : uuid,
            sourceID: sourceID,
            title: field("OPFCalendarEventCopySummary").nilIfEmpty ?? "Untitled Event",
            startAt: start, endAt: end,
            location: field("OPFCalendarEventCopyLocation"),
            details: field("OPFCalendarEventCopyDescriptionPlain", "OPFCalendarEventCopyDescription"),
            organizer: field("OPFCalendarEventCopyOrganizer"), attendees: attendees,
            isAllDay: boolean("OPFCalendarEventGetIsAllDayEvent"),
            isPrivate: boolean("OPFCalendarEventGetIsPrivate"),
            hasReminder: boolean("OPFCalendarEventGetHasReminder"),
            reminderMinutes: Int(field("OPFCalendarEventCopyReminderDelta")), recurrence: recurrence
        ))
    }

    private func field(_ names: String...) -> String {
        for name in names where !(fields[name] ?? "").isEmpty { return fields[name] ?? "" }
        return ""
    }
    private func boolean(_ name: String) -> Bool {
        Self.boolean(field(name))
    }
    private static func boolean(_ value: String) -> Bool { ["1", "true", "yes"].contains(value.lowercased()) }
}

enum OLMItemDateParser {
    static func parse(_ value: String) -> Date? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) { return date }
        for format in ["yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyyMMdd'T'HHmmss'Z'"] {
            let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX")
            parser.timeZone = TimeZone(secondsFromGMT: 0); parser.dateFormat = format
            if let date = parser.date(from: value) { return date }
        }
        return nil
    }
}

enum OLMItemMailboxParser {
    static func parse(_ value: String) -> (name: String, address: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expression = try? NSRegularExpression(
            pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#,
            options: [.caseInsensitive]
        ) else { return ("", trimmed) }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = expression.firstMatch(in: trimmed, range: range),
              let emailRange = Range(match.range, in: trimmed) else {
            return ("", trimmed)
        }
        let address = String(trimmed[emailRange])
        let name = trimmed.replacingCharacters(in: emailRange, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " <>;,\t\r\n"))
        return (name, address)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
