import Foundation

@main
enum OutlookCompatibilitySmokeCheck {
    static func main() {
        require(
            OLMTimeZoneResolver.normalizedIdentifier("Eastern Standard Time") == "America/New_York",
            "Windows Eastern timezone mapping"
        )
        require(
            OLMTimeZoneResolver.normalizedIdentifier("(UTC) Coordinated Universal Time") == "UTC",
            "Outlook UTC label mapping"
        )
        require(
            OLMItemDateParser.parse("/Date(1700000000000)/")
                == Date(timeIntervalSince1970: 1_700_000_000),
            ".NET millisecond date"
        )
        require(
            OLMItemDateParser.parse("20260723T143000Z") != nil,
            "compact UTC date"
        )

        let source = ArchiveItemSource(
            id: "synthetic-timezone-calendar",
            accountID: "synthetic@example.invalid",
            name: "Timezone Fixtures",
            kind: .calendar,
            entryPath: "synthetic/Calendar.xml"
        )
        let xml = """
        <appointments>
          <appointment>
            <OPFCalendarEventCopyUUID>dst-series@example.invalid</OPFCalendarEventCopyUUID>
            <OPFCalendarEventCopySummary>DST Fixture</OPFCalendarEventCopySummary>
            <OPFCalendarEventCopyStartTime>2026-03-01T09:00:00</OPFCalendarEventCopyStartTime>
            <OPFCalendarEventCopyEndTime>2026-03-01T10:00:00</OPFCalendarEventCopyEndTime>
            <OPFCalendarEventCopyTimeZoneName>Eastern Standard Time</OPFCalendarEventCopyTimeZoneName>
            <OPFCalendarEventIsRecurring>1</OPFCalendarEventIsRecurring>
            <OPFRecurrencePatternType>recursWeekly</OPFRecurrencePatternType>
            <OPFRecurrencePatternInterval>1</OPFRecurrencePatternInterval>
            <OPFRecurrenceIsNumbered>1</OPFRecurrenceIsNumbered>
            <OPFRecurrenceGetOccurenceCount>3E0</OPFRecurrenceGetOccurenceCount>
          </appointment>
          <appointment>
            <OPFCalendarEventCopyUUID>all-day@example.invalid</OPFCalendarEventCopyUUID>
            <OPFCalendarEventCopySummary>All Day Fixture</OPFCalendarEventCopySummary>
            <OPFCalendarEventCopyStartTime>2026-07-23</OPFCalendarEventCopyStartTime>
            <OPFCalendarEventCopyEndTime>2026-07-23</OPFCalendarEventCopyEndTime>
            <OPFCalendarEventGetIsAllDayEvent>1</OPFCalendarEventGetIsAllDayEvent>
          </appointment>
          <appointment>
            <OPFCalendarEventCopyUUID>relative-monthly@example.invalid</OPFCalendarEventCopyUUID>
            <OPFCalendarEventCopySummary>Relative Monthly Fixture</OPFCalendarEventCopySummary>
            <OPFCalendarEventCopyStartTime>2026-01-20T09:00:00</OPFCalendarEventCopyStartTime>
            <OPFCalendarEventCopyEndTime>2026-01-20T10:00:00</OPFCalendarEventCopyEndTime>
            <OPFCalendarEventIsRecurring>1</OPFCalendarEventIsRecurring>
            <OPFRecurrencePatternType>OPFRecurrencePatternRelativeMonthly</OPFRecurrencePatternType>
            <OPFRecurrencePatternInterval>1</OPFRecurrencePatternInterval>
            <OPFRecurrencePatternWeek>3</OPFRecurrencePatternWeek>
            <OPFRecurrencePatternDaysOfWeek><tuesday>1</tuesday></OPFRecurrencePatternDaysOfWeek>
          </appointment>
          <appointment>
            <OPFCalendarEventCopyUUID>relative-yearly@example.invalid</OPFCalendarEventCopyUUID>
            <OPFCalendarEventCopySummary>Relative Yearly Fixture</OPFCalendarEventCopySummary>
            <OPFCalendarEventCopyStartTime>2026-11-27T09:00:00</OPFCalendarEventCopyStartTime>
            <OPFCalendarEventCopyEndTime>2026-11-27T10:00:00</OPFCalendarEventCopyEndTime>
            <OPFCalendarEventIsRecurring>1</OPFCalendarEventIsRecurring>
            <OPFRecurrencePatternType>OPFRecurrencePatternRelativeYearly</OPFRecurrencePatternType>
            <OPFRecurrencePatternInterval>1</OPFRecurrencePatternInterval>
            <OPFRecurrencePatternMonth>11</OPFRecurrencePatternMonth>
            <OPFRecurrencePatternWeek>5</OPFRecurrencePatternWeek>
            <OPFRecurrencePatternDaysOfWeek><friday>1</friday></OPFRecurrencePatternDaysOfWeek>
          </appointment>
        </appointments>
        """
        let events = OLMCalendarParser().parse(data: Data(xml.utf8), source: source)
        require(events.count == 4, "cross-version event fixture count")
        require(events[0].timeZoneIdentifier == "America/New_York", "normalized event timezone")
        require(
            CalendarOccurrenceEngine.supportsRecurrenceFrequency("recursWeekly"),
            "cross-version recurrence alias"
        )
        require(
            CalendarOccurrenceEngine.supportsRecurrenceFrequency("OPFRecurrencePatternDaily")
                && CalendarOccurrenceEngine.supportsRecurrenceFrequency("OPFRecurrencePatternWeekly")
                && CalendarOccurrenceEngine.supportsRecurrenceFrequency("OPFRecurrencePatternAbsoluteMonthly")
                && CalendarOccurrenceEngine.supportsRecurrenceFrequency("OPFRecurrencePatternAbsoluteYearly")
                && CalendarOccurrenceEngine.supportsRecurrenceFrequency("OPFRecurrencePatternRelativeMonthly")
                && CalendarOccurrenceEngine.supportsRecurrenceFrequency("OPFRecurrencePatternRelativeYearly"),
            "OPF recurrence labels used by production Outlook archives"
        )
        require(
            events[0].recurrence?.occurrenceCount == 3,
            "scientific numbered occurrence count"
        )
        require(
            events[2].recurrence?.weekOfMonth == 3
                && events[2].recurrence?.daysOfWeek == [3]
                && events[3].recurrence?.weekOfMonth == 5
                && events[3].recurrence?.monthOfYear == 11
                && events[3].recurrence?.daysOfWeek == [6],
            "relative recurrence fields"
        )
        let boundStart = events[0].startAt
        let invalidBoundEvent = CalendarEventRecord(
            id: "invalid-bound", sourceID: "calendar.xml", title: "Synthetic",
            startAt: boundStart, endAt: boundStart.addingTimeInterval(3_600),
            location: "", details: "", organizer: "", attendees: [],
            isAllDay: false, isPrivate: false, hasReminder: false, reminderMinutes: nil,
            recurrence: .init(
                frequency: "OPFRecurrencePatternWeekly", interval: 1,
                occurrenceCount: nil, endDate: boundStart.addingTimeInterval(-86_400)
            )
        )
        require(
            !CalendarOccurrenceEngine.occurrences(
                for: invalidBoundEvent,
                intersecting: DateInterval(
                    start: boundStart.addingTimeInterval(-1),
                    end: boundStart.addingTimeInterval(7_200)
                )
            ).isEmpty,
            "invalid recurrence end does not hide the stored master"
        )

        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = TimeZone(identifier: "America/New_York")!
        let march = DateInterval(
            start: eastern.date(from: DateComponents(year: 2026, month: 3, day: 1))!,
            end: eastern.date(from: DateComponents(year: 2026, month: 3, day: 31))!
        )
        let occurrences = CalendarOccurrenceEngine.occurrences(
            for: [events[0]], intersecting: march, calendar: eastern
        )
        require(occurrences.count == 3, "weekly DST occurrence count")
        require(
            occurrences.allSatisfy { eastern.component(.hour, from: $0.startAt) == 9 },
            "weekly recurrence preserves local time across DST"
        )
        require(
            Set(occurrences.map(\.materializedEvent.calendarUID)).count == occurrences.count,
            "materialized range occurrences have unique interoperable UIDs"
        )
        require(
            events[1].endAt.timeIntervalSince(events[1].startAt) == 86_400,
            "same-date all-day event receives exclusive next-day end"
        )
        let february = DateInterval(
            start: eastern.date(from: DateComponents(year: 2026, month: 2, day: 1))!,
            end: eastern.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        )
        let relativeMonthly = CalendarOccurrenceEngine.occurrences(
            for: events[2], intersecting: february, calendar: eastern
        )
        require(
            relativeMonthly.count == 1
                && eastern.component(.day, from: relativeMonthly[0].startAt) == 17
                && eastern.component(.weekday, from: relativeMonthly[0].startAt) == 3,
            "third Tuesday relative-monthly expansion"
        )
        let november2027 = DateInterval(
            start: eastern.date(from: DateComponents(year: 2027, month: 11, day: 1))!,
            end: eastern.date(from: DateComponents(year: 2027, month: 12, day: 1))!
        )
        let relativeYearly = CalendarOccurrenceEngine.occurrences(
            for: events[3], intersecting: november2027, calendar: eastern
        )
        require(
            relativeYearly.count == 1
                && eastern.component(.day, from: relativeYearly[0].startAt) == 26
                && eastern.component(.weekday, from: relativeYearly[0].startAt) == 6,
            "last Friday relative-yearly expansion"
        )

        let exported = String(
            decoding: ContactCalendarExporter.calendarData([events[0]], format: .ics),
            as: UTF8.self
        )
        require(
            exported.contains("RRULE:FREQ=WEEKLY;INTERVAL=1;BYDAY=SU;COUNT=3"),
            "cross-version recurrence export"
        )
        let relativeExport = String(
            decoding: ContactCalendarExporter.calendarData(
                [events[2], events[3]], format: .ics
            ),
            as: UTF8.self
        )
        require(
            relativeExport.contains("RRULE:FREQ=MONTHLY;INTERVAL=1;BYDAY=3TU")
                && relativeExport.contains("RRULE:FREQ=YEARLY;INTERVAL=1;BYMONTH=11;BYDAY=-1FR"),
            "relative recurrence iCalendar export"
        )
        let materialized = occurrences[1].materializedEvent
        require(materialized.recurrence == nil && materialized.startAt == occurrences[1].startAt,
                "date-range occurrence materialization")

        print("Outlook recurrence, timezone, and date compatibility checks passed")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError("Failed: \(label)") }
    }
}
