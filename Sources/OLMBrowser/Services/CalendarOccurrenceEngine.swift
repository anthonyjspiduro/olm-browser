import Foundation

struct CalendarOccurrence: Identifiable, Hashable, Sendable {
    let event: CalendarEventRecord
    let startAt: Date
    let endAt: Date

    var id: String { "\(event.id)#\(startAt.timeIntervalSinceReferenceDate)" }

    func intersects(_ range: DateInterval) -> Bool {
        if endAt <= startAt { return range.contains(startAt) }
        return endAt > range.start && startAt < range.end
    }

    var materializedEvent: CalendarEventRecord {
        CalendarEventRecord(
            id: id,
            sourceID: event.sourceID,
            title: event.title,
            startAt: startAt,
            endAt: endAt,
            location: event.location,
            details: event.details,
            organizer: event.organizer,
            attendees: event.attendees,
            isAllDay: event.isAllDay,
            isPrivate: event.isPrivate,
            hasReminder: event.hasReminder,
            reminderMinutes: event.reminderMinutes,
            recurrence: nil,
            seriesID: "",
            calendarUID: event.calendarUID.isEmpty
                ? ""
                : "\(event.calendarUID)#\(Int64(startAt.timeIntervalSince1970))",
            recurrenceID: nil,
            isCancelled: event.isCancelled,
            status: event.status,
            timeZoneIdentifier: event.timeZoneIdentifier
        )
    }
}

enum CalendarOccurrenceEngine {
    static func supportsRecurrenceFrequency(_ value: String) -> Bool {
        recurrenceKind(value) != nil
    }

    static func occurrences(
        for events: [CalendarEventRecord],
        intersecting range: DateInterval,
        calendar: Calendar = .current
    ) -> [CalendarOccurrence] {
        let exceptions = Dictionary(grouping: events.filter { $0.recurrenceID != nil }) {
            $0.seriesID.isEmpty ? $0.id : $0.seriesID
        }
        return events.flatMap { event -> [CalendarOccurrence] in
            if event.recurrenceID != nil {
                guard !event.isCancelled else { return [] }
                return standaloneOccurrence(for: event, intersecting: range)
            }
            guard !event.isCancelled else { return [] }
            let generated = occurrences(for: event, intersecting: range, calendar: calendar)
            let seriesKey = event.seriesID.isEmpty ? event.id : event.seriesID
            let replacedStarts = exceptions[seriesKey, default: []].compactMap(\.recurrenceID)
            guard !replacedStarts.isEmpty else { return generated }
            return generated.filter { occurrence in
                !replacedStarts.contains { abs($0.timeIntervalSince(occurrence.startAt)) < 1 }
            }
        }
            .sorted { left, right in
                left.startAt == right.startAt
                    ? left.event.title.localizedCaseInsensitiveCompare(right.event.title) == .orderedAscending
                    : left.startAt < right.startAt
            }
    }

    static func occurrences(
        for event: CalendarEventRecord,
        intersecting range: DateInterval,
        calendar: Calendar = .current
    ) -> [CalendarOccurrence] {
        guard !event.isCancelled, event.recurrenceID == nil else {
            return event.isCancelled ? [] : standaloneOccurrence(for: event, intersecting: range)
        }
        guard let recurrence = event.recurrence,
              let kind = recurrenceKind(recurrence.frequency) else {
            let occurrence = CalendarOccurrence(event: event, startAt: event.startAt, endAt: event.endAt)
            return occurrence.intersects(range) ? [occurrence] : []
        }

        let interval = max(1, recurrence.interval)
        let duration = max(0, event.endAt.timeIntervalSince(event.startAt))
        let countLimit = recurrence.occurrenceCount.flatMap { $0 > 0 ? $0 : nil } ?? Int.max
        let recurrenceEnd = recurrence.endDate.flatMap { $0 >= event.startAt ? $0 : nil }
        var recurrenceCalendar = calendar
        if let timeZone = TimeZone(identifier: event.timeZoneIdentifier) {
            recurrenceCalendar.timeZone = timeZone
        }
        var result: [CalendarOccurrence] = []
        var occurrenceIndex = 0
        var periodIndex = countLimit == Int.max
            ? estimatedPeriodSkip(
                from: event.startAt,
                to: range.start.addingTimeInterval(-duration),
                kind: kind,
                interval: interval,
                calendar: recurrenceCalendar
            )
            : 0
        var safetyLimit = 0
        while occurrenceIndex < countLimit, safetyLimit < 100_000 {
            guard let period = period(
                index: periodIndex,
                event: event,
                recurrence: recurrence,
                kind: kind,
                interval: interval,
                calendar: recurrenceCalendar
            ) else { break }
            if period.anchor >= range.end, period.starts.allSatisfy({ $0 >= range.end }) { break }
            for start in period.starts.sorted() where start >= event.startAt {
                if let recurrenceEnd, start > recurrenceEnd { return result }
                if occurrenceIndex >= countLimit { return result }
                let end = start.addingTimeInterval(duration)
                let occurrence = CalendarOccurrence(event: event, startAt: start, endAt: end)
                if occurrence.intersects(range) { result.append(occurrence) }
                occurrenceIndex += 1
            }
            periodIndex += 1
            safetyLimit += 1
        }
        return result
    }

    private static func standaloneOccurrence(
        for event: CalendarEventRecord,
        intersecting range: DateInterval
    ) -> [CalendarOccurrence] {
        let occurrence = CalendarOccurrence(event: event, startAt: event.startAt, endAt: event.endAt)
        return occurrence.intersects(range) ? [occurrence] : []
    }

    private enum RecurrenceKind: Equatable {
        case daily
        case weekly
        case absoluteMonthly
        case relativeMonthly
        case absoluteYearly
        case relativeYearly
    }

    private struct RecurrencePeriod {
        let anchor: Date
        let starts: [Date]
    }

    private static func recurrenceKind(_ value: String) -> RecurrenceKind? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "0", "daily", "day", "recursdaily", "opfrecurrencepatterndaily":
            .daily
        case "1", "weekly", "week", "recursweekly", "opfrecurrencepatternweekly":
            .weekly
        case "2", "monthly", "month", "recursmonthly", "absolutemonthly",
             "opfrecurrencepatternabsolutemonthly":
            .absoluteMonthly
        case "3", "relativemonthly", "recursmonthnth",
             "opfrecurrencepatternrelativemonthly":
            .relativeMonthly
        case "4", "5", "yearly", "annual", "year", "recursyearly", "absoluteyearly",
             "opfrecurrencepatternabsoluteyearly":
            .absoluteYearly
        case "6", "relativeyearly", "recursyearnth",
             "opfrecurrencepatternrelativeyearly":
            .relativeYearly
        default: nil
        }
    }

    private static func period(
        index: Int,
        event: CalendarEventRecord,
        recurrence: CalendarRecurrence,
        kind: RecurrenceKind,
        interval: Int,
        calendar: Calendar
    ) -> RecurrencePeriod? {
        switch kind {
        case .daily:
            guard let start = calendar.date(
                byAdding: .day, value: index * interval, to: event.startAt
            ) else { return nil }
            return RecurrencePeriod(anchor: start, starts: [start])
        case .weekly:
            let weekStart = startOfWeek(containing: event.startAt, calendar: calendar)
            guard let anchor = calendar.date(
                byAdding: .weekOfYear, value: index * interval, to: weekStart
            ) else { return nil }
            let weekdays = recurrence.daysOfWeek.isEmpty
                ? [calendar.component(.weekday, from: event.startAt)]
                : recurrence.daysOfWeek
            let starts = weekdays.compactMap { weekday -> Date? in
                let offset = (weekday - calendar.firstWeekday + 7) % 7
                guard let day = calendar.date(byAdding: .day, value: offset, to: anchor) else {
                    return nil
                }
                return applyingTime(of: event.startAt, to: day, calendar: calendar)
            }
            return RecurrencePeriod(anchor: anchor, starts: starts)
        case .absoluteMonthly, .relativeMonthly:
            guard let firstMonth = calendar.dateInterval(of: .month, for: event.startAt)?.start,
                  let anchor = calendar.date(
                    byAdding: .month, value: index * interval, to: firstMonth
                  ) else { return nil }
            let start: Date?
            if kind == .absoluteMonthly {
                start = date(
                    inMonthContaining: anchor,
                    day: recurrence.dayOfMonth
                        ?? calendar.component(.day, from: event.startAt),
                    timeFrom: event.startAt,
                    calendar: calendar
                )
            } else {
                start = relativeDate(
                    inMonthContaining: anchor,
                    weekdays: recurrence.daysOfWeek,
                    week: recurrence.weekOfMonth,
                    fallback: event.startAt,
                    calendar: calendar
                )
            }
            return RecurrencePeriod(anchor: anchor, starts: start.map { [$0] } ?? [])
        case .absoluteYearly, .relativeYearly:
            guard let firstYear = calendar.dateInterval(of: .year, for: event.startAt)?.start,
                  let yearAnchor = calendar.date(
                    byAdding: .year, value: index * interval, to: firstYear
                  ) else { return nil }
            let month = min(12, max(1, recurrence.monthOfYear
                ?? calendar.component(.month, from: event.startAt)))
            guard let anchor = calendar.date(
                byAdding: .month, value: month - 1, to: yearAnchor
            ) else { return nil }
            let start: Date?
            if kind == .absoluteYearly {
                start = date(
                    inMonthContaining: anchor,
                    day: recurrence.dayOfMonth
                        ?? calendar.component(.day, from: event.startAt),
                    timeFrom: event.startAt,
                    calendar: calendar
                )
            } else {
                start = relativeDate(
                    inMonthContaining: anchor,
                    weekdays: recurrence.daysOfWeek,
                    week: recurrence.weekOfMonth,
                    fallback: event.startAt,
                    calendar: calendar
                )
            }
            return RecurrencePeriod(anchor: anchor, starts: start.map { [$0] } ?? [])
        }
    }

    private static func estimatedPeriodSkip(
        from start: Date,
        to target: Date,
        kind: RecurrenceKind,
        interval: Int,
        calendar: Calendar
    ) -> Int {
        let difference: Int
        switch kind {
        case .daily:
            difference = calendar.dateComponents([.day], from: start, to: target).day ?? 0
        case .weekly:
            difference = calendar.dateComponents([.day], from: start, to: target).day.map { $0 / 7 } ?? 0
        case .absoluteMonthly, .relativeMonthly:
            difference = calendar.dateComponents([.month], from: start, to: target).month ?? 0
        case .absoluteYearly, .relativeYearly:
            difference = calendar.dateComponents([.year], from: start, to: target).year ?? 0
        }
        return max(0, difference / interval - 1)
    }

    private static func startOfWeek(containing date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -offset, to: day) ?? day
    }

    private static func applyingTime(
        of source: Date,
        to day: Date,
        calendar: Calendar
    ) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        let time = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: source)
        components.hour = time.hour
        components.minute = time.minute
        components.second = time.second
        components.nanosecond = time.nanosecond
        return calendar.date(from: components)
    }

    private static func date(
        inMonthContaining month: Date,
        day: Int,
        timeFrom source: Date,
        calendar: Calendar
    ) -> Date? {
        var components = calendar.dateComponents([.year, .month], from: month)
        components.day = day
        let time = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: source)
        components.hour = time.hour
        components.minute = time.minute
        components.second = time.second
        components.nanosecond = time.nanosecond
        guard let result = calendar.date(from: components),
              calendar.component(.month, from: result) == components.month,
              calendar.component(.day, from: result) == day else {
            return nil
        }
        return result
    }

    private static func relativeDate(
        inMonthContaining month: Date,
        weekdays: [Int],
        week: Int?,
        fallback: Date,
        calendar: Calendar
    ) -> Date? {
        let selected = Set(weekdays.isEmpty
            ? [calendar.component(.weekday, from: fallback)]
            : weekdays)
        guard let monthRange = calendar.range(of: .day, in: .month, for: month) else {
            return nil
        }
        let candidates = monthRange.compactMap {
            date(
                inMonthContaining: month, day: $0,
                timeFrom: fallback, calendar: calendar
            )
        }.filter { selected.contains(calendar.component(.weekday, from: $0)) }
        let ordinal = min(5, max(1, week ?? 1))
        if ordinal == 5 { return candidates.last }
        let matchingByWeekday = selected.compactMap { weekday -> Date? in
            let dates = candidates.filter {
                calendar.component(.weekday, from: $0) == weekday
            }
            let index = ordinal - 1
            return dates.indices.contains(index) ? dates[index] : nil
        }
        return matchingByWeekday.min()
    }
}
