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
        recurrenceComponent(value) != nil
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
              let component = recurrenceComponent(recurrence.frequency) else {
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
        var occurrenceIndex = 0
        var start = event.startAt

        if start < range.start {
            let estimated = estimatedSkip(
                from: start, to: range.start, component: component,
                interval: interval, calendar: recurrenceCalendar
            )
            if estimated > 0, estimated < countLimit,
               let advanced = recurrenceCalendar.date(byAdding: component, value: estimated * interval, to: start) {
                occurrenceIndex = estimated
                start = advanced
            }
            while start.addingTimeInterval(duration) < range.start,
                  occurrenceIndex < countLimit,
                  let next = recurrenceCalendar.date(byAdding: component, value: interval, to: start) {
                occurrenceIndex += 1
                start = next
            }
        }

        var result: [CalendarOccurrence] = []
        var safetyLimit = 0
        while occurrenceIndex < countLimit, start < range.end, safetyLimit < 10_000 {
            if let recurrenceEnd, start > recurrenceEnd { break }
            let end = start.addingTimeInterval(duration)
            let occurrence = CalendarOccurrence(event: event, startAt: start, endAt: end)
            if occurrence.intersects(range) { result.append(occurrence) }
            guard let next = recurrenceCalendar.date(byAdding: component, value: interval, to: start), next > start else { break }
            occurrenceIndex += 1
            safetyLimit += 1
            start = next
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

    private static func recurrenceComponent(_ value: String) -> Calendar.Component? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "0", "daily", "day", "recursdaily", "opfrecurrencepatterndaily": .day
        case "1", "weekly", "week", "recursweekly", "opfrecurrencepatternweekly": .weekOfYear
        case "2", "3", "monthly", "month", "recursmonthly", "absolutemonthly",
             "opfrecurrencepatternabsolutemonthly": .month
        case "4", "5", "yearly", "annual", "year", "recursyearly", "absoluteyearly",
             "opfrecurrencepatternabsoluteyearly": .year
        default: nil
        }
    }

    private static func estimatedSkip(
        from start: Date,
        to target: Date,
        component: Calendar.Component,
        interval: Int,
        calendar: Calendar
    ) -> Int {
        let difference: Int
        switch component {
        case .day:
            difference = calendar.dateComponents([.day], from: start, to: target).day ?? 0
        case .weekOfYear:
            difference = calendar.dateComponents([.day], from: start, to: target).day.map { $0 / 7 } ?? 0
        case .month:
            difference = calendar.dateComponents([.month], from: start, to: target).month ?? 0
        case .year:
            difference = calendar.dateComponents([.year], from: start, to: target).year ?? 0
        default:
            difference = 0
        }
        return max(0, difference / interval - 1)
    }
}
