import Foundation

enum ContactExportFormat: String, CaseIterable, Identifiable, Sendable {
    case vcf
    case csv
    var id: String { rawValue }
    var label: String { self == .vcf ? "vCard" : "CSV" }
}

enum CalendarExportFormat: String, CaseIterable, Identifiable, Sendable {
    case ics
    case csv
    var id: String { rawValue }
    var label: String { self == .ics ? "iCalendar" : "CSV" }
}

enum ContactCalendarExporter {
    static func contactData(_ contacts: [ContactRecord], format: ContactExportFormat) -> Data {
        let text = format == .vcf ? vCards(contacts) : contactCSV(contacts)
        return Data(text.utf8)
    }

    static func calendarData(_ events: [CalendarEventRecord], format: CalendarExportFormat) -> Data {
        let text = format == .ics ? iCalendar(events) : calendarCSV(events)
        return Data(text.utf8)
    }

    private static func vCards(_ contacts: [ContactRecord]) -> String {
        contacts.map { contact in
            var lines = ["BEGIN:VCARD", "VERSION:4.0"]
            lines.append("FN:\(vCard(contact.displayName))")
            lines.append("N:\(vCard(contact.lastName));\(vCard(contact.firstName));\(vCard(contact.middleName));;")
            if contact.isDistributionList { lines.append("KIND:group") }
            if !contact.company.isEmpty || !contact.department.isEmpty {
                lines.append("ORG:\(vCard(contact.company));\(vCard(contact.department))")
            }
            if !contact.jobTitle.isEmpty { lines.append("TITLE:\(vCard(contact.jobTitle))") }
            if !contact.nickname.isEmpty { lines.append("NICKNAME:\(vCard(contact.nickname))") }
            for email in contact.emails {
                lines.append("EMAIL;TYPE=\(token(email.label)):\(vCard(email.address))")
            }
            for phone in contact.phoneNumbers {
                lines.append("TEL;TYPE=\(token(phone.label)):\(vCard(phone.number))")
            }
            for address in contact.postalAddresses {
                lines.append(
                    "ADR;TYPE=\(token(address.label)):;;\(vCard(address.street));\(vCard(address.city));\(vCard(address.region));\(vCard(address.postalCode));\(vCard(address.country))"
                )
            }
            if let birthday = contact.birthday { lines.append("BDAY:\(day(birthday))") }
            if let anniversary = contact.anniversary { lines.append("ANNIVERSARY:\(day(anniversary))") }
            if !contact.categories.isEmpty {
                lines.append("CATEGORIES:\(contact.categories.map(vCard).joined(separator: ","))")
            }
            for website in contact.websites { lines.append("URL:\(vCard(website))") }
            for member in contact.groupMembers where !member.address.isEmpty {
                lines.append("MEMBER:mailto:\(vCard(member.address))")
            }
            if !contact.officeLocation.isEmpty { lines.append("X-OLM-OFFICE:\(vCard(contact.officeLocation))") }
            if !contact.manager.isEmpty { lines.append("X-OLM-MANAGER:\(vCard(contact.manager))") }
            if !contact.assistant.isEmpty { lines.append("X-OLM-ASSISTANT:\(vCard(contact.assistant))") }
            if !contact.spouse.isEmpty { lines.append("X-OLM-SPOUSE:\(vCard(contact.spouse))") }
            if !contact.notes.isEmpty { lines.append("NOTE:\(vCard(contact.notes))") }
            if let modified = contact.modifiedAt { lines.append("REV:\(utc(modified))") }
            lines.append("END:VCARD")
            return fold(lines)
        }.joined(separator: "\r\n") + (contacts.isEmpty ? "" : "\r\n")
    }

    private static func contactCSV(_ contacts: [ContactRecord]) -> String {
        let header = [
            "Display Name", "First Name", "Middle Name", "Last Name", "Nickname",
            "Company", "Department", "Job Title", "Office", "Manager", "Assistant", "Spouse",
            "Email Addresses", "Phone Numbers", "Postal Addresses", "Websites",
            "Birthday", "Anniversary", "Categories", "Distribution List", "Group Members",
            "Notes", "Modified"
        ]
        let rows = contacts.map { contact in
            let postalAddresses = contact.postalAddresses.map { address in
                let flattened = address.formatted.replacingOccurrences(of: "\n", with: ", ")
                return "\(address.label): \(flattened)"
            }.joined(separator: "; ")
            let emailAddresses = contact.emails.map(\.address).joined(separator: "; ")
            let phoneNumbers = contact.phoneNumbers.map(\.number).joined(separator: "; ")
            let groupMembers = contact.groupMembers.map {
                $0.address.isEmpty ? $0.name : $0.address
            }.joined(separator: "; ")
            return [contact.displayName, contact.firstName, contact.middleName, contact.lastName,
             contact.nickname, contact.company, contact.department, contact.jobTitle,
             contact.officeLocation, contact.manager, contact.assistant, contact.spouse,
             emailAddresses, phoneNumbers, postalAddresses,
             contact.websites.joined(separator: "; "),
             contact.birthday.map(day) ?? "", contact.anniversary.map(day) ?? "",
             contact.categories.joined(separator: "; "),
             contact.isDistributionList ? "true" : "false",
             groupMembers,
             contact.notes,
             contact.modifiedAt.map(ISO8601DateFormatter().string) ?? ""]
        }
        return ([header] + rows).map { $0.map(csv).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    private static func iCalendar(_ events: [CalendarEventRecord]) -> String {
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//OLM Browser//Read-only viewer//EN", "CALSCALE:GREGORIAN"]
        for event in events {
            lines.append("BEGIN:VEVENT")
            let uid = event.calendarUID.isEmpty
                ? opaqueUID(event.seriesID.isEmpty ? event.id : event.seriesID)
                : event.calendarUID
            lines.append("UID:\(ical(uid))")
            if let recurrenceID = event.recurrenceID {
                lines.append("RECURRENCE-ID:\(utc(recurrenceID))")
            }
            if event.isAllDay {
                lines.append("DTSTART;VALUE=DATE:\(day(event.startAt))")
                lines.append("DTEND;VALUE=DATE:\(day(event.endAt))")
            } else {
                lines.append("DTSTART:\(utc(event.startAt))")
                lines.append("DTEND:\(utc(event.endAt))")
            }
            lines.append("SUMMARY:\(ical(event.title))")
            if !event.location.isEmpty { lines.append("LOCATION:\(ical(event.location))") }
            if !event.details.isEmpty { lines.append("DESCRIPTION:\(ical(event.details))") }
            if !event.organizer.isEmpty {
                let organizer = OLMItemMailboxParser.parse(event.organizer)
                if organizer.address.contains("@") {
                    let cn = organizer.name.isEmpty ? "" : ";CN=\(parameter(organizer.name))"
                    lines.append("ORGANIZER\(cn):mailto:\(ical(organizer.address))")
                } else {
                    lines.append("X-OLM-ORGANIZER:\(ical(event.organizer))")
                }
            }
            for attendee in event.attendees where !attendee.address.isEmpty {
                let cn = attendee.name.isEmpty ? "" : ";CN=\(parameter(attendee.name))"
                let role = attendeeRole(attendee.type).map { ";ROLE=\($0)" } ?? ""
                let status = attendeeStatus(attendee.status).map { ";PARTSTAT=\($0)" } ?? ""
                let rsvp = attendee.responseRequested ? ";RSVP=TRUE" : ""
                lines.append("ATTENDEE\(cn)\(role)\(status)\(rsvp):mailto:\(ical(attendee.address))")
            }
            if event.isPrivate { lines.append("CLASS:PRIVATE") }
            if event.isCancelled { lines.append("STATUS:CANCELLED") }
            else if !event.status.isEmpty { lines.append("X-OLM-STATUS:\(ical(event.status))") }
            if !event.timeZoneIdentifier.isEmpty {
                lines.append("X-OLM-TIMEZONE:\(ical(event.timeZoneIdentifier))")
            }
            if let recurrence = event.recurrence, let frequency = recurrenceFrequency(recurrence.frequency) {
                var rule = "FREQ=\(frequency);INTERVAL=\(max(1, recurrence.interval))"
                if let count = recurrence.occurrenceCount, count > 0 { rule += ";COUNT=\(count)" }
                else if let end = recurrence.endDate, end >= event.startAt {
                    rule += ";UNTIL=\(utc(end))"
                }
                lines.append("RRULE:\(rule)")
            }
            if event.hasReminder, let minutes = event.reminderMinutes {
                lines += ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Reminder", "TRIGGER:-PT\(abs(minutes))M", "END:VALARM"]
            }
            lines.append("END:VEVENT")
        }
        lines.append("END:VCALENDAR")
        return fold(lines) + "\r\n"
    }

    private static func calendarCSV(_ events: [CalendarEventRecord]) -> String {
        let header = [
            "Title", "Start", "End", "Time Zone", "All Day", "Location", "Organizer",
            "Attendees", "Private", "Status", "Canceled", "Recurring", "Recurrence ID", "Details"
        ]
        let rows = events.map { event in
            [event.title, ISO8601DateFormatter().string(from: event.startAt), ISO8601DateFormatter().string(from: event.endAt),
             event.timeZoneIdentifier, event.isAllDay ? "true" : "false", event.location, event.organizer,
             event.attendees.map { $0.address.isEmpty ? $0.name : $0.address }.joined(separator: "; "),
             event.isPrivate ? "true" : "false", event.status, event.isCancelled ? "true" : "false",
             event.recurrence == nil ? "false" : "true",
             event.recurrenceID.map(ISO8601DateFormatter().string) ?? "", event.details]
        }
        return ([header] + rows).map { $0.map(csv).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    private static func csv(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    private static func vCard(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\n", with: "\\n") }
    private static func ical(_ value: String) -> String { vCard(value).replacingOccurrences(of: "\r", with: "") }
    private static func token(_ value: String) -> String { value.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }.nilIfEmpty ?? "OTHER" }
    private static func parameter(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "'") + "\"" }
    private static func utc(_ date: Date) -> String { date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeZone(separator: .omitted)).replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "") }
    private static func day(_ date: Date) -> String { date.formatted(.iso8601.year().month().day()).replacingOccurrences(of: "-", with: "") }
    private static func recurrenceFrequency(_ value: String) -> String? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "0", "daily", "day", "recursdaily", "opfrecurrencepatterndaily": "DAILY"
        case "1", "weekly", "week", "recursweekly", "opfrecurrencepatternweekly": "WEEKLY"
        case "2", "3", "monthly", "month", "recursmonthly", "absolutemonthly",
             "opfrecurrencepatternabsolutemonthly": "MONTHLY"
        case "4", "5", "yearly", "annual", "year", "recursyearly", "absoluteyearly",
             "opfrecurrencepatternabsoluteyearly": "YEARLY"
        default: nil
        }
    }
    private static func opaqueUID(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "\(String(hash, radix: 16))@olm-browser.local"
    }
    private static func attendeeRole(_ value: String) -> String? {
        switch value.lowercased() {
        case "1", "required": "REQ-PARTICIPANT"
        case "2", "optional": "OPT-PARTICIPANT"
        case "3", "resource": "NON-PARTICIPANT"
        default: nil
        }
    }
    private static func attendeeStatus(_ value: String) -> String? {
        switch value.lowercased() {
        case "2", "tentative": "TENTATIVE"
        case "3", "accepted", "accept": "ACCEPTED"
        case "4", "declined", "decline": "DECLINED"
        case "0", "5", "none", "notresponded": "NEEDS-ACTION"
        default: nil
        }
    }

    private static func fold(_ lines: [String]) -> String {
        lines.flatMap { line -> [String] in
            var parts: [String] = []
            var part = ""
            var bytes = 0
            for scalar in line.unicodeScalars {
                let width = scalar.utf8.count
                if bytes + width > 75, !part.isEmpty {
                    parts.append(part)
                    part = " "
                    bytes = 1
                }
                part.unicodeScalars.append(scalar)
                bytes += width
            }
            parts.append(part)
            return parts
        }.joined(separator: "\r\n")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
