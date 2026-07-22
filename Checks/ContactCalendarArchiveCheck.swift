import Foundation

@main
enum ContactCalendarArchiveCheck {
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else {
            print("Usage: ContactCalendarArchiveCheck <archive.olm> [--calendar]")
            return
        }
        let includesCalendar = CommandLine.arguments.contains("--calendar")
        let reader = NativeOLMArchiveReader()
        let snapshot = try reader.openArchive(at: URL(fileURLWithPath: CommandLine.arguments[1]))

        print("Contact collections: \(snapshot.contactSources.count)")
        print("Calendar collections: \(snapshot.calendarSources.count)")

        var contactCount = 0
        var contactsWithEmail = 0
        var contactsWithPhone = 0
        for source in snapshot.contactSources {
            let page = try reader.loadContacts(sourceID: source.id, matching: "", offset: 0, limit: Int.max)
            contactCount += page.totalCount
            contactsWithEmail += page.records.count { !$0.emails.isEmpty }
            contactsWithPhone += page.records.count { !$0.phoneNumbers.isEmpty }
        }
        print("Contacts parsed: \(contactCount)")
        print("Contacts with email: \(contactsWithEmail)")
        print("Contacts with phone: \(contactsWithPhone)")

        guard includesCalendar else {
            print("Calendar parsing skipped (pass --calendar for the large validation)")
            return
        }
        var eventCount = 0
        var datedEvents = 0
        var titledEvents = 0
        var eventsWithLocation = 0
        var eventsWithOrganizer = 0
        var eventsWithAttendees = 0
        var recurringEvents = 0
        var exportSamples = 0
        for source in snapshot.calendarSources {
            let page = try reader.loadCalendarEvents(sourceID: source.id, matching: "", offset: 0, limit: Int.max)
            eventCount += page.totalCount
            datedEvents += page.records.count { $0.startAt != .distantPast }
            titledEvents += page.records.count { $0.title != "Untitled Event" }
            eventsWithLocation += page.records.count { !$0.location.isEmpty }
            eventsWithOrganizer += page.records.count { !$0.organizer.isEmpty }
            eventsWithAttendees += page.records.count { !$0.attendees.isEmpty }
            recurringEvents += page.records.count { $0.recurrence != nil }
            if let sample = page.records.first {
                let data = ContactCalendarExporter.calendarData([sample], format: .ics)
                if String(decoding: data, as: UTF8.self).contains("BEGIN:VEVENT") { exportSamples += 1 }
            }
        }
        print("Calendar events parsed: \(eventCount)")
        print("Calendar events with recognized dates: \(datedEvents)")
        print("Calendar events with titles: \(titledEvents)")
        print("Calendar events with locations: \(eventsWithLocation)")
        print("Calendar events with organizers: \(eventsWithOrganizer)")
        print("Calendar events with attendees: \(eventsWithAttendees)")
        print("Recurring calendar events: \(recurringEvents)")
        print("Calendar collections with valid export samples: \(exportSamples)")
    }
}
