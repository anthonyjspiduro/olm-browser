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
        var distributionLists = 0
        var distributionListMembers = 0
        for source in snapshot.contactSources {
            let page = try reader.loadContacts(sourceID: source.id, matching: "", offset: 0, limit: Int.max)
            contactCount += page.totalCount
            contactsWithEmail += page.records.count { !$0.emails.isEmpty }
            contactsWithPhone += page.records.count { !$0.phoneNumbers.isEmpty }
            distributionLists += page.records.count { $0.isDistributionList }
            distributionListMembers += page.records.reduce(0) { $0 + $1.groupMembers.count }
        }
        print("Contacts parsed: \(contactCount)")
        print("Contacts with email: \(contactsWithEmail)")
        print("Contacts with phone: \(contactsWithPhone)")
        print("Distribution lists parsed: \(distributionLists)")
        print("Distribution-list members parsed: \(distributionListMembers)")

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
        var eventsWithTimeZones = 0
        var unsupportedRecurrences = 0
        var recurrenceTypeCounts: [String: Int] = [:]
        var exportSamples = 0
        var monthGridSamples = 0
        var renderedMonthOccurrences = 0
        var emptySampleCancelled = 0
        var emptySampleInvalidRecurrenceEnd = 0
        var emptySampleOther = 0
        for source in snapshot.calendarSources {
            let page = try reader.loadCalendarEvents(sourceID: source.id, matching: "", offset: 0, limit: Int.max)
            eventCount += page.totalCount
            datedEvents += page.records.count { $0.startAt != .distantPast }
            titledEvents += page.records.count { $0.title != "Untitled Event" }
            eventsWithLocation += page.records.count { !$0.location.isEmpty }
            eventsWithOrganizer += page.records.count { !$0.organizer.isEmpty }
            eventsWithAttendees += page.records.count { !$0.attendees.isEmpty }
            recurringEvents += page.records.count { $0.recurrence != nil }
            for recurrence in page.records.compactMap(\.recurrence) {
                recurrenceTypeCounts[recurrence.frequency, default: 0] += 1
            }
            eventsWithTimeZones += page.records.count { !$0.timeZoneIdentifier.isEmpty }
            unsupportedRecurrences += page.records.count {
                guard let recurrence = $0.recurrence else { return false }
                return !CalendarOccurrenceEngine.supportsRecurrenceFrequency(recurrence.frequency)
            }
            if let sample = page.records.first {
                let data = ContactCalendarExporter.calendarData([sample], format: .ics)
                if String(decoding: data, as: UTF8.self).contains("BEGIN:VEVENT") { exportSamples += 1 }
                if let month = Calendar.current.dateInterval(of: .month, for: sample.startAt) {
                    let occurrences = CalendarOccurrenceEngine.occurrences(
                        for: page.records, intersecting: month
                    )
                    if !occurrences.isEmpty {
                        monthGridSamples += 1
                    } else if sample.isCancelled {
                        emptySampleCancelled += 1
                    } else if let recurrenceEnd = sample.recurrence?.endDate,
                              recurrenceEnd < sample.startAt {
                        emptySampleInvalidRecurrenceEnd += 1
                    } else {
                        emptySampleOther += 1
                    }
                    renderedMonthOccurrences += occurrences.count
                }
            }
        }
        print("Calendar events parsed: \(eventCount)")
        print("Calendar events with recognized dates: \(datedEvents)")
        print("Calendar events with titles: \(titledEvents)")
        print("Calendar events with locations: \(eventsWithLocation)")
        print("Calendar events with organizers: \(eventsWithOrganizer)")
        print("Calendar events with attendees: \(eventsWithAttendees)")
        print("Recurring calendar events: \(recurringEvents)")
        print("Calendar events with time zones: \(eventsWithTimeZones)")
        print("Unsupported recurrence patterns: \(unsupportedRecurrences)")
        for (type, count) in recurrenceTypeCounts.sorted(by: { $0.key < $1.key }) {
            print("Recurrence type \(type.debugDescription): \(count)")
        }
        print("Calendar collections with valid export samples: \(exportSamples)")
        print("Calendar collections with populated month grids: \(monthGridSamples)")
        print("Empty samples canceled: \(emptySampleCancelled)")
        print("Empty samples with invalid recurrence end: \(emptySampleInvalidRecurrenceEnd)")
        print("Other empty samples: \(emptySampleOther)")
        print("Aggregate rendered month occurrences: \(renderedMonthOccurrences)")
        let diagnostics = reader.operationalStatus().itemDiagnostics
        print("Diagnostic contacts counted: \(diagnostics.parsedContacts)")
        print("Diagnostic calendar events counted: \(diagnostics.parsedCalendarEvents)")
    }
}
