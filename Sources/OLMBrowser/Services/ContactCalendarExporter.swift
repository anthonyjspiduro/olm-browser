import Foundation

enum ContactExportFormat: String, CaseIterable, Identifiable {
    case vcf
    case csv
    var id: String { rawValue }
    var label: String { self == .vcf ? "vCard" : "CSV" }
}

enum CalendarExportFormat: String, CaseIterable, Identifiable {
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
            if !contact.company.isEmpty { lines.append("ORG:\(vCard(contact.company))") }
            if !contact.jobTitle.isEmpty { lines.append("TITLE:\(vCard(contact.jobTitle))") }
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
            if !contact.categories.isEmpty {
                lines.append("CATEGORIES:\(contact.categories.map(vCard).joined(separator: ","))")
            }
            if !contact.notes.isEmpty { lines.append("NOTE:\(vCard(contact.notes))") }
            if let modified = contact.modifiedAt { lines.append("REV:\(utc(modified))") }
            lines.append("END:VCARD")
            return fold(lines)
        }.joined(separator: "\r\n") + (contacts.isEmpty ? "" : "\r\n")
    }

    private static func contactCSV(_ contacts: [ContactRecord]) -> String {
        let header = ["Display Name", "First Name", "Middle Name", "Last Name", "Company", "Job Title", "Email Addresses", "Phone Numbers", "Postal Addresses", "Birthday", "Categories", "Notes", "Modified"]
        let rows = contacts.map { contact in
            [contact.displayName, contact.firstName, contact.middleName, contact.lastName,
             contact.company, contact.jobTitle,
             contact.emails.map { $0.address }.joined(separator: "; "),
             contact.phoneNumbers.map { $0.number }.joined(separator: "; "),
             contact.postalAddresses.map { "\($0.label): \($0.formatted.replacingOccurrences(of: "\n", with: ", "))" }.joined(separator: "; "),
             contact.birthday.map(day) ?? "",
             contact.categories.joined(separator: "; "), contact.notes,
             contact.modifiedAt.map(ISO8601DateFormatter().string) ?? ""]
        }
        return ([header] + rows).map { $0.map(csv).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    private static func iCalendar(_ events: [CalendarEventRecord]) -> String {
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//OLM Browser//Read-only recovery//EN", "CALSCALE:GREGORIAN"]
        for event in events {
            lines.append("BEGIN:VEVENT")
            lines.append("UID:\(ical(event.seriesID.isEmpty ? event.id : event.seriesID))")
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
                else if let end = recurrence.endDate { rule += ";UNTIL=\(utc(end))" }
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
        let header = ["Title", "Start", "End", "All Day", "Location", "Organizer", "Attendees", "Private", "Recurring", "Details"]
        let rows = events.map { event in
            [event.title, ISO8601DateFormatter().string(from: event.startAt), ISO8601DateFormatter().string(from: event.endAt),
             event.isAllDay ? "true" : "false", event.location, event.organizer,
             event.attendees.map { $0.address.isEmpty ? $0.name : $0.address }.joined(separator: "; "),
             event.isPrivate ? "true" : "false", event.recurrence == nil ? "false" : "true", event.details]
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
        case "0", "daily", "day": "DAILY"
        case "1", "weekly", "week": "WEEKLY"
        case "2", "3", "monthly", "month": "MONTHLY"
        case "4", "5", "yearly", "annual", "year": "YEARLY"
        default: nil
        }
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
