import SwiftUI

struct CalendarTimelineView: View {
    enum Mode {
        case day
        case week

        var dayCount: Int { self == .day ? 1 : 7 }
        var navigationComponent: Calendar.Component { self == .day ? .day : .weekOfYear }
    }

    @EnvironmentObject private var store: ArchiveStore
    let mode: Mode
    @State private var occurrences: [CalendarOccurrence] = []
    @State private var isComputing = false

    private let calendar = Calendar.current
    private let hourHeight: CGFloat = 52
    private let timeGutterWidth: CGFloat = 58

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                navigationHeader
                Divider()
                dayHeaders(availableWidth: geometry.size.width)
                if !allDayOccurrences.isEmpty {
                    allDayStrip(availableWidth: geometry.size.width)
                    Divider()
                }
                timeline(availableWidth: geometry.size.width)
            }
            .overlay(alignment: .topTrailing) {
                if isComputing {
                    ProgressView().controlSize(.small).padding(12)
                }
            }
        }
        .task(id: renderIdentity) {
            isComputing = true
            let events = store.calendarEvents
            let range = visibleRange
            let workingCalendar = calendar
            let computed = await Task.detached(priority: .userInitiated) {
                CalendarOccurrenceEngine.occurrences(
                    for: events, intersecting: range, calendar: workingCalendar
                )
            }.value
            guard !Task.isCancelled else { return }
            occurrences = computed
            isComputing = false
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Visible \(mode == .day ? "Day" : "Week") as iCalendar") {
                        store.exportCalendarEvents(
                            occurrences.map(\.materializedEvent), format: .ics
                        )
                    }
                    Button("Visible \(mode == .day ? "Day" : "Week") as CSV") {
                        store.exportCalendarEvents(
                            occurrences.map(\.materializedEvent), format: .csv
                        )
                    }
                    Divider()
                    Button(store.showsAllCalendarSources
                           ? "Export All Calendars as iCalendar"
                           : "Export Entire Calendar as iCalendar") {
                        store.exportEntireCalendarAsICS()
                    }
                } label: {
                    Label("Export Calendar", systemImage: "square.and.arrow.up")
                }
                .disabled(store.calendarEvents.isEmpty || store.isExportingItems)
            }
        }
    }

    private var visibleDays: [Date] {
        let selected = calendar.startOfDay(for: store.selectedCalendarDate)
        let start: Date
        if mode == .day {
            start = selected
        } else {
            let weekday = calendar.component(.weekday, from: selected)
            let offset = (weekday - calendar.firstWeekday + 7) % 7
            start = calendar.date(byAdding: .day, value: -offset, to: selected) ?? selected
        }
        return (0..<mode.dayCount).compactMap {
            calendar.date(byAdding: .day, value: $0, to: start)
        }
    }

    private var visibleRange: DateInterval {
        let start = visibleDays.first ?? store.selectedCalendarDate
        let end = calendar.date(
            byAdding: .day, value: mode.dayCount, to: start
        ) ?? start.addingTimeInterval(Double(mode.dayCount) * 86_400)
        return DateInterval(start: start, end: end)
    }

    private var allDayOccurrences: [CalendarOccurrence] {
        occurrences.filter { $0.event.isAllDay }
    }

    private var minimumContentWidth: CGFloat {
        timeGutterWidth + CGFloat(mode.dayCount) * (mode == .day ? 320 : 112)
    }

    private var navigationHeader: some View {
        HStack(spacing: 8) {
            Button { move(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
            Button("Today") {
                store.selectedCalendarDate = calendar.startOfDay(for: Date())
            }
            .controlSize(.small)
            Button { move(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
            Spacer()
            Text(headerTitle)
                .font(.title3.bold())
            Spacer()
            Text("\(occurrences.count.formatted()) occurrences")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var headerTitle: String {
        guard let first = visibleDays.first, let last = visibleDays.last else { return "" }
        if mode == .day {
            return first.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        }
        return "\(first.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(.dateTime.month(.abbreviated).day().year()))"
    }

    private func dayHeaders(availableWidth: CGFloat) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                Color.clear.frame(width: timeGutterWidth, height: 48)
                ForEach(visibleDays, id: \.self) { day in
                    Button {
                        store.selectedCalendarDate = day
                    } label: {
                        VStack(spacing: 2) {
                            Text(day, format: .dateTime.weekday(.abbreviated))
                                .font(.caption.weight(.semibold))
                            Text(calendar.component(.day, from: day), format: .number)
                                .font(.headline)
                                .frame(width: 30, height: 26)
                                .background(
                                    calendar.isDateInToday(day)
                                        ? Color.accentColor : Color.clear,
                                    in: Circle()
                                )
                                .foregroundStyle(calendar.isDateInToday(day) ? .white : .primary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .frame(width: dayColumnWidth(availableWidth: availableWidth), height: 48)
                    .background(
                        calendar.isDate(day, inSameDayAs: store.selectedCalendarDate)
                            ? Color.accentColor.opacity(0.08) : Color.clear
                    )
                }
            }
            .frame(minWidth: max(availableWidth, minimumContentWidth), alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    private func allDayStrip(availableWidth: CGFloat) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 0) {
                Text("all-day")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: timeGutterWidth, alignment: .trailing)
                    .padding(.top, 5)
                ForEach(visibleDays, id: \.self) { day in
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(allDayOccurrences(on: day)) { occurrence in
                            CalendarAllDayOccurrenceButton(occurrence: occurrence) {
                                select(occurrence)
                            }
                        }
                    }
                    .padding(3)
                    .frame(
                        width: dayColumnWidth(availableWidth: availableWidth),
                        alignment: .topLeading
                    )
                    .frame(minHeight: 34, alignment: .topLeading)
                }
            }
            .frame(minWidth: max(availableWidth, minimumContentWidth), alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: 110)
    }

    private func timeline(availableWidth: CGFloat) -> some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(hourLabel(hour))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: timeGutterWidth - 8, height: hourHeight, alignment: .topTrailing)
                    }
                }
                ForEach(visibleDays, id: \.self) { day in
                    CalendarTimelineDayColumn(
                        day: day,
                        occurrences: timedOccurrences(on: day),
                        width: dayColumnWidth(availableWidth: availableWidth),
                        hourHeight: hourHeight,
                        selection: store.selectedCalendarEventIDs,
                        select: select
                    )
                }
            }
            .frame(
                minWidth: max(availableWidth, minimumContentWidth),
                minHeight: hourHeight * 24,
                alignment: .topLeading
            )
        }
    }

    private func dayColumnWidth(availableWidth: CGFloat) -> CGFloat {
        max(
            mode == .day ? 320 : 112,
            (availableWidth - timeGutterWidth) / CGFloat(mode.dayCount)
        )
    }

    private func timedOccurrences(on day: Date) -> [CalendarOccurrence] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        return occurrences.filter { !$0.event.isAllDay && $0.intersects(interval) }
    }

    private func occurrence(_ occurrence: CalendarOccurrence, intersects day: Date) -> Bool {
        calendar.dateInterval(of: .day, for: day).map(occurrence.intersects) ?? false
    }

    private func allDayOccurrences(on day: Date) -> [CalendarOccurrence] {
        allDayOccurrences.filter { occurrence($0, intersects: day) }
    }

    private func hourLabel(_ hour: Int) -> String {
        guard let date = calendar.date(
            from: DateComponents(year: 2001, month: 1, day: 1, hour: hour)
        ) else { return "\(hour):00" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func move(_ value: Int) {
        store.selectedCalendarDate = calendar.date(
            byAdding: mode.navigationComponent,
            value: value,
            to: store.selectedCalendarDate
        ) ?? store.selectedCalendarDate
    }

    private func select(_ occurrence: CalendarOccurrence) {
        store.selectedCalendarEventIDs = [occurrence.event.id]
        store.selectedCalendarDate = calendar.startOfDay(for: occurrence.startAt)
    }

    private var renderIdentity: CalendarTimelineIdentity {
        CalendarTimelineIdentity(
            mode: mode == .day ? "day" : "week",
            sourceID: store.selectedCalendarSourceID,
            searchText: store.searchText,
            eventCount: store.calendarEvents.count,
            firstEventID: store.calendarEvents.first?.id,
            lastEventID: store.calendarEvents.last?.id,
            rangeStart: visibleRange.start,
            rangeEnd: visibleRange.end
        )
    }
}

private struct CalendarAllDayOccurrenceButton: View {
    let occurrence: CalendarOccurrence
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(occurrence.event.title)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .background(
                    Color.accentColor.opacity(0.18),
                    in: RoundedRectangle(cornerRadius: 4)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct CalendarTimelineDayColumn: View {
    let day: Date
    let occurrences: [CalendarOccurrence]
    let width: CGFloat
    let hourHeight: CGFloat
    let selection: Set<CalendarEventRecord.ID>
    let select: (CalendarOccurrence) -> Void

    private let calendar = Calendar.current

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { _ in
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 1)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .frame(height: hourHeight)
                }
            }
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 1)
                .frame(maxHeight: .infinity)

            ForEach(placements) { placement in
                Button { select(placement.occurrence) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(placement.occurrence.event.title)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(2)
                        Text(placement.occurrence.startAt, format: .dateTime.hour().minute())
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(4)
                    .frame(
                        width: placementWidth(lanes: placement.laneCount),
                        height: placement.height,
                        alignment: .topLeading
                    )
                    .background(
                        selection.contains(placement.occurrence.event.id)
                            ? Color.accentColor.opacity(0.35)
                            : Color.accentColor.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color.accentColor).frame(width: 3)
                    }
                }
                .buttonStyle(.plain)
                .offset(
                    x: 3 + CGFloat(placement.lane) * placementWidth(lanes: placement.laneCount),
                    y: placement.y
                )
                .accessibilityLabel(
                    "\(placement.occurrence.event.title), \(placement.occurrence.startAt.formatted(date: .omitted, time: .shortened))"
                )
            }
        }
        .frame(width: width, height: hourHeight * 24, alignment: .topLeading)
        .background(
            calendar.isDateInToday(day) ? Color.accentColor.opacity(0.035) : Color.clear
        )
        .clipped()
    }

    private var placements: [TimelinePlacement] {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86_400)
        var laneEnds: [Date] = []
        var preliminary: [(CalendarOccurrence, Int, CGFloat, CGFloat)] = []
        for occurrence in occurrences.sorted(by: { $0.startAt < $1.startAt }) {
            let clippedStart = max(occurrence.startAt, dayStart)
            let clippedEnd = min(max(occurrence.endAt, clippedStart.addingTimeInterval(900)), dayEnd)
            let lane = laneEnds.firstIndex(where: { $0 <= clippedStart }) ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(clippedEnd) } else { laneEnds[lane] = clippedEnd }
            let startMinutes = clippedStart.timeIntervalSince(dayStart) / 60
            let durationMinutes = max(15, clippedEnd.timeIntervalSince(clippedStart) / 60)
            preliminary.append((
                occurrence, lane,
                CGFloat(startMinutes / 60) * hourHeight,
                max(22, CGFloat(durationMinutes / 60) * hourHeight)
            ))
        }
        let laneCount = max(1, laneEnds.count)
        return preliminary.map {
            TimelinePlacement(
                occurrence: $0.0, lane: $0.1, laneCount: laneCount,
                y: $0.2, height: $0.3
            )
        }
    }

    private func placementWidth(lanes: Int) -> CGFloat {
        max(44, (width - 6) / CGFloat(max(1, lanes)))
    }
}

private struct TimelinePlacement: Identifiable {
    let occurrence: CalendarOccurrence
    let lane: Int
    let laneCount: Int
    let y: CGFloat
    let height: CGFloat
    var id: CalendarOccurrence.ID { occurrence.id }
}

private struct CalendarTimelineIdentity: Hashable {
    let mode: String
    let sourceID: String?
    let searchText: String
    let eventCount: Int
    let firstEventID: String?
    let lastEventID: String?
    let rangeStart: Date
    let rangeEnd: Date
}
