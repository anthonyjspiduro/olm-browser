import Foundation

@main
enum CalendarOccurrenceSmokeCheck {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = date(2026, 7, 1, 14, calendar: calendar)
        let event = CalendarEventRecord(
            id: "synthetic-recurring", sourceID: "synthetic-calendar",
            title: "Weekly recovery review", startAt: start,
            endAt: start.addingTimeInterval(3_600), location: "", details: "",
            organizer: "", attendees: [], isAllDay: false, isPrivate: false,
            hasReminder: false, reminderMinutes: nil,
            recurrence: CalendarRecurrence(frequency: "weekly", interval: 1, occurrenceCount: 4, endDate: nil)
        )
        let july = DateInterval(
            start: date(2026, 7, 1, 0, calendar: calendar),
            end: date(2026, 8, 1, 0, calendar: calendar)
        )
        let occurrences = CalendarOccurrenceEngine.occurrences(for: [event], intersecting: july, calendar: calendar)
        require(occurrences.count == 4, "weekly recurrence count")
        require(calendar.component(.day, from: occurrences[2].startAt) == 15, "weekly recurrence date")

        let august = DateInterval(
            start: date(2026, 8, 1, 0, calendar: calendar),
            end: date(2026, 9, 1, 0, calendar: calendar)
        )
        require(CalendarOccurrenceEngine.occurrences(for: [event], intersecting: august, calendar: calendar).isEmpty, "occurrence limit")

        var series = event
        series.seriesID = "series-1"
        var moved = CalendarEventRecord(
            id: "series-1#exception", sourceID: "synthetic-calendar",
            title: "Moved recovery review",
            startAt: date(2026, 7, 16, 16, calendar: calendar),
            endAt: date(2026, 7, 16, 17, calendar: calendar),
            location: "", details: "", organizer: "", attendees: [],
            isAllDay: false, isPrivate: false, hasReminder: false,
            reminderMinutes: nil, recurrence: nil
        )
        moved.seriesID = "series-1"
        moved.recurrenceID = date(2026, 7, 15, 14, calendar: calendar)
        let withException = CalendarOccurrenceEngine.occurrences(
            for: [series, moved], intersecting: july, calendar: calendar
        )
        require(withException.count == 4, "exception replaces occurrence")
        require(withException.contains { calendar.component(.day, from: $0.startAt) == 16 }, "moved exception date")
        require(!withException.contains { $0.startAt == moved.recurrenceID }, "original exception removed")

        var cancelled = moved
        cancelled.isCancelled = true
        let withCancellation = CalendarOccurrenceEngine.occurrences(
            for: [series, cancelled], intersecting: july, calendar: calendar
        )
        require(withCancellation.count == 3, "cancelled exception removes occurrence")
        print("Calendar month occurrence checks passed")
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError("Failed: \(label)") }
    }
}
