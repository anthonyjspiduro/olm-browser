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
    private var categories: [String] = []
    private var websites: [String] = []
    private var groupMembers: [ContactGroupMember] = []
    private var progress: (@Sendable (Int) -> Void)?

    func parse(
        data: Data,
        source: ArchiveItemSource,
        progress: (@Sendable (Int) -> Void)? = nil
    ) -> [ContactRecord] {
        reset(source: source)
        self.progress = progress
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        if !Task.isCancelled { progress?(records.count) }
        return records
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if Task.isCancelled { parser.abortParsing(); return }
        elements.append(elementName)
        text = ""
        if elementName == "contact" {
            inContact = true
            fields = [:]
            emails = []
            phones = []
            categories = []
            websites = []
            groupMembers = []
        }
        if elementName == "contactEmailAddress" {
            let address = attributeDict["OPFContactEmailAddressAddress"] ?? ""
            let label = attributeDict["OPFContactEmailAddressType"]
                ?? attributeDict["OPFContactEmailAddressName"] ?? "Email"
            if !address.isEmpty { emails.append(.init(label: label, address: address)) }
        }
        let lowerName = elementName.lowercased()
        if inContact, lowerName.contains("member"), elementName != "contact" {
            let address = Self.firstAttribute(
                attributeDict,
                names: [
                    "OPFDistributionListMemberAddress", "OPFContactListMemberAddress",
                    "OPFMemberAddress", "OPFContactEmailAddressAddress", "emailAddress", "address"
                ]
            )
            let name = Self.firstAttribute(
                attributeDict,
                names: [
                    "OPFDistributionListMemberName", "OPFContactListMemberName",
                    "OPFMemberName", "OPFContactEmailAddressName", "displayName", "name"
                ]
            )
            if !address.isEmpty || !name.isEmpty {
                groupMembers.append(.init(name: name, address: address))
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if Task.isCancelled { parser.abortParsing(); return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inContact, elementName.hasPrefix("OPF"), !value.isEmpty {
            fields[elementName] = value
            if ["phone", "fax", "pager", "telex"].contains(where: { elementName.localizedCaseInsensitiveContains($0) }) {
                phones.append(.init(label: Self.readableLabel(elementName, removing: "OPFContactCopy"), number: value))
            }
            if elementName.localizedCaseInsensitiveContains("category") {
                categories.append(value)
            }
            if elementName.localizedCaseInsensitiveContains("website")
                || elementName.localizedCaseInsensitiveContains("webpage") {
                websites.append(value)
            }
        } else if inContact, elementName == "contactEmailAddress", !value.isEmpty,
                  !emails.contains(where: { $0.address == value }) {
            let mailbox = OLMItemMailboxParser.parse(value)
            emails.append(.init(label: "Email", address: mailbox.address))
        } else if inContact, elementName.localizedCaseInsensitiveContains("member"), !value.isEmpty {
            let mailbox = OLMItemMailboxParser.parse(value)
            if !mailbox.address.isEmpty {
                groupMembers.append(.init(name: mailbox.name, address: mailbox.address))
            }
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
        let display = field(
            "OPFContactCopyDisplayName",
            "OPFContactCopyDistributionListName",
            "OPFContactCopyGroupName"
        )
        records.append(ContactRecord(
            id: "\(sourcePath)#contact-\(ordinal)", sourceID: sourceID,
            displayName: display.isEmpty ? (composed.isEmpty ? "Unnamed Contact" : composed) : display,
            firstName: first, middleName: middle, lastName: last,
            company: field("OPFContactCopyBusinessCompany"),
            jobTitle: field("OPFContactCopyBusinessTitle", "OPFContactCopyJobTitle"),
            emails: Self.unique(emails), phoneNumbers: Self.unique(phones),
            notes: field("OPFContactCopyNotesPlain", "OPFContactCopyNotes"),
            modifiedAt: OLMItemDateParser.parse(field("OPFContactCopyModDate")),
            postalAddresses: ["Home", "Business", "Other"].compactMap(postalAddress),
            birthday: OLMItemDateParser.parse(field("OPFContactCopyBirthday", "OPFContactCopyBirthDate")),
            categories: Self.unique(categories.flatMap(Self.splitCategories)),
            nickname: field("OPFContactCopyNickName", "OPFContactCopyNickname"),
            department: field("OPFContactCopyBusinessDepartment", "OPFContactCopyDepartment"),
            officeLocation: field("OPFContactCopyBusinessOffice", "OPFContactCopyOfficeLocation"),
            manager: field("OPFContactCopyManagerName", "OPFContactCopyManager"),
            assistant: field("OPFContactCopyAssistantName", "OPFContactCopyAssistant"),
            spouse: field("OPFContactCopySpouseName", "OPFContactCopySpouse"),
            websites: Self.unique(websites),
            anniversary: OLMItemDateParser.parse(field("OPFContactCopyAnniversary")),
            isDistributionList: isDistributionList,
            groupMembers: Self.unique(groupMembers)
        ))
        if records.count.isMultiple(of: 25) { progress?(records.count) }
    }

    private func field(_ names: String...) -> String {
        for name in names where !(fields[name] ?? "").isEmpty { return fields[name] ?? "" }
        return ""
    }

    private func reset(source: ArchiveItemSource) {
        sourceID = source.id; sourcePath = source.entryPath; records = []; ordinal = 0
        inContact = false; elements = []; text = ""; fields = [:]; emails = []; phones = []
        categories = []; websites = []; groupMembers = []; progress = nil
    }

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }
    private static func readableLabel(_ value: String, removing prefix: String) -> String {
        value.replacingOccurrences(of: prefix, with: "")
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
    }

    private func postalAddress(_ label: String) -> ContactPostalAddress? {
        let street = field(
            "OPFContactCopy\(label)AddressStreet",
            "OPFContactCopy\(label)Street"
        )
        let city = field(
            "OPFContactCopy\(label)AddressCity",
            "OPFContactCopy\(label)City"
        )
        let region = field(
            "OPFContactCopy\(label)AddressState",
            "OPFContactCopy\(label)State",
            "OPFContactCopy\(label)AddressRegion"
        )
        let postalCode = field(
            "OPFContactCopy\(label)AddressPostalCode",
            "OPFContactCopy\(label)PostalCode",
            "OPFContactCopy\(label)AddressZip"
        )
        let country = field(
            "OPFContactCopy\(label)AddressCountry",
            "OPFContactCopy\(label)Country"
        )
        guard ![street, city, region, postalCode, country].allSatisfy(\.isEmpty) else { return nil }
        return ContactPostalAddress(
            label: label, street: street, city: city, region: region,
            postalCode: postalCode, country: country
        )
    }

    private static func splitCategories(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var isDistributionList: Bool {
        !groupMembers.isEmpty || [
            "OPFContactIsDistributionList", "OPFContactGetIsDistributionList",
            "OPFContactCopyIsDistributionList"
        ].contains { Self.boolean(fields[$0] ?? "") }
    }

    private static func boolean(_ value: String) -> Bool {
        ["1", "true", "yes"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func firstAttribute(_ attributes: [String: String], names: [String]) -> String {
        for name in names {
            if let value = attributes[name], !value.isEmpty { return value }
        }
        return ""
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
    private var progress: (@Sendable (Int) -> Void)?

    func parse(
        data: Data,
        source: ArchiveItemSource,
        progress: (@Sendable (Int) -> Void)? = nil
    ) -> [CalendarEventRecord] {
        sourceID = source.id; sourcePath = source.entryPath; records = []; ordinal = 0
        self.progress = progress
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        if !Task.isCancelled { progress?(records.count) }
        return records
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if Task.isCancelled { parser.abortParsing(); return }
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
        if Task.isCancelled { parser.abortParsing(); return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inAppointment, elementName.hasPrefix("OPF"), !value.isEmpty { fields[elementName] = value }
        if inAppointment, elementName == "appointmentAttendee", !value.isEmpty,
           !attendees.contains(where: { $0.address == value }) {
            let mailbox = OLMItemMailboxParser.parse(value)
            attendees.append(.init(name: mailbox.name, address: mailbox.address, type: "", status: "", responseRequested: false))
        }
        if elementName == "appointment", inAppointment {
            appendEvent()
            if records.count.isMultiple(of: 100) { progress?(records.count) }
            inAppointment = false
        }
        text = ""
    }

    private func appendEvent() {
        ordinal += 1
        let rawTimeZone = field(
            "OPFCalendarEventCopyTimeZone",
            "OPFCalendarEventCopyTimeZoneName",
            "OPFCalendarEventCopyStartTimeZone"
        )
        let timeZoneIdentifier = OLMTimeZoneResolver.normalizedIdentifier(rawTimeZone)
        let start = OLMItemDateParser.parse(
            field("OPFCalendarEventCopyStartTime"),
            timeZoneIdentifier: timeZoneIdentifier
        ) ?? .distantPast
        let isAllDay = boolean("OPFCalendarEventGetIsAllDayEvent")
        let parsedEnd = OLMItemDateParser.parse(
            field("OPFCalendarEventCopyEndTime"),
            timeZoneIdentifier: timeZoneIdentifier
        ) ?? start
        let end: Date
        if isAllDay, parsedEnd <= start {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
            end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        } else {
            end = parsedEnd
        }
        let recurring = boolean("OPFCalendarEventIsRecurring")
        let recurrence = recurring ? CalendarRecurrence(
            frequency: field("OPFRecurrencePatternType"),
            interval: Int(field("OPFRecurrencePatternInterval")) ?? 1,
            occurrenceCount: Int(field("OPFRecurrenceGetOccurenceCount")),
            endDate: OLMItemDateParser.parse(
                field("OPFRecurrenceCopyEndDate"),
                timeZoneIdentifier: timeZoneIdentifier
            )
        ) : nil
        let uuid = field("OPFCalendarEventCopyUUID")
        let recurrenceID = OLMItemDateParser.parse(
            field(
                "OPFCalendarEventCopyRecurrenceID",
                "OPFCalendarEventCopyOriginalStartTime"
            ),
            timeZoneIdentifier: timeZoneIdentifier
        )
        let status = field("OPFCalendarEventCopyStatus", "OPFCalendarEventGetStatus")
        let isCancelled = boolean("OPFCalendarEventGetIsCancelled")
            || boolean("OPFCalendarEventIsCancelled")
            || status.localizedCaseInsensitiveContains("cancel")
        let recordID: String
        let scopedSeriesID = uuid.isEmpty ? "" : "\(sourcePath)#\(uuid)"
        if uuid.isEmpty {
            recordID = "\(sourcePath)#appointment-\(ordinal)"
        } else if let recurrenceID {
            recordID = "\(scopedSeriesID)#exception-\(recurrenceID.timeIntervalSinceReferenceDate)"
        } else {
            recordID = scopedSeriesID
        }
        records.append(CalendarEventRecord(
            id: recordID,
            sourceID: sourceID,
            title: field("OPFCalendarEventCopySummary").nilIfEmpty ?? "Untitled Event",
            startAt: start, endAt: end,
            location: field("OPFCalendarEventCopyLocation"),
            details: field("OPFCalendarEventCopyDescriptionPlain", "OPFCalendarEventCopyDescription"),
            organizer: field("OPFCalendarEventCopyOrganizer"), attendees: attendees,
            isAllDay: isAllDay,
            isPrivate: boolean("OPFCalendarEventGetIsPrivate"),
            hasReminder: boolean("OPFCalendarEventGetHasReminder"),
            reminderMinutes: Int(field("OPFCalendarEventCopyReminderDelta")), recurrence: recurrence,
            seriesID: scopedSeriesID,
            calendarUID: uuid,
            recurrenceID: recurrenceID,
            isCancelled: isCancelled,
            status: status,
            timeZoneIdentifier: timeZoneIdentifier
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
    static func parse(_ value: String, timeZoneIdentifier: String? = nil) -> Date? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("/Date("),
           let expression = try? NSRegularExpression(pattern: #"/Date\((-?\d+)(?:[+-]\d{4})?\)/"#),
           let match = expression.firstMatch(
               in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)
           ),
           let millisecondsRange = Range(match.range(at: 1), in: value),
           let milliseconds = Double(value[millisecondsRange]) {
            return Date(timeIntervalSince1970: milliseconds / 1_000)
        }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) { return date }
        let timeZone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
            ?? TimeZone(secondsFromGMT: 0)!
        for format in [
            "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss",
            "yyyyMMdd'T'HHmmss'Z'", "yyyyMMdd'T'HHmmssZ", "yyyyMMdd'T'HHmmss",
            "yyyy-MM-dd"
        ] {
            let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX")
            parser.calendar = Calendar(identifier: .gregorian)
            parser.timeZone = timeZone; parser.dateFormat = format
            if let date = parser.date(from: value) { return date }
        }
        return nil
    }
}

enum OLMTimeZoneResolver {
    static func normalizedIdentifier(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if TimeZone(identifier: trimmed) != nil { return trimmed }
        let normalized = trimmed.lowercased()
        return windowsMappings[normalized] ?? {
            if normalized == "utc" || normalized == "gmt"
                || normalized.contains("coordinated universal time") {
                return "UTC"
            }
            return trimmed
        }()
    }

    private static let windowsMappings: [String: String] = [
        "eastern standard time": "America/New_York",
        "central standard time": "America/Chicago",
        "mountain standard time": "America/Denver",
        "pacific standard time": "America/Los_Angeles",
        "atlantic standard time": "America/Halifax",
        "gmt standard time": "Europe/London",
        "w. europe standard time": "Europe/Berlin",
        "central europe standard time": "Europe/Budapest",
        "romance standard time": "Europe/Paris",
        "india standard time": "Asia/Kolkata",
        "china standard time": "Asia/Shanghai",
        "tokyo standard time": "Asia/Tokyo",
        "aus eastern standard time": "Australia/Sydney",
        "new zealand standard time": "Pacific/Auckland"
    ]
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
