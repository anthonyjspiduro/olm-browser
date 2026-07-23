import SwiftUI

struct CalendarMonthView: View {
    @EnvironmentObject private var store: ArchiveStore
    @State private var cachedOccurrences: [CalendarOccurrence] = []

    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(minimum: 30), spacing: 3), count: 7)

    var body: some View {
        VStack(spacing: 0) {
            monthHeader
            weekdayHeader
            monthGrid
        }
        .overlay {
            if store.isLoadingItems && store.calendarEvents.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading calendar…").font(.callout).foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if !store.isLoadingItems && store.calendarEvents.isEmpty {
                ContentUnavailableView(
                    "No Events", systemImage: "calendar",
                    description: Text("This calendar contains no matching records.")
                )
            }
        }
        .task(id: renderIdentity) {
            let events = store.calendarEvents
            let range = visibleRange
            let workingCalendar = calendar
            let computed = await Task.detached(priority: .userInitiated) {
                CalendarOccurrenceEngine.occurrences(for: events, intersecting: range, calendar: workingCalendar)
            }.value
            guard !Task.isCancelled else { return }
            cachedOccurrences = computed
        }
        .toolbar { exportToolbar }
    }

    private var visibleDays: [Date] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: store.displayedCalendarMonth) else { return [] }
        let weekday = calendar.component(.weekday, from: monthInterval.start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let gridStart = calendar.date(byAdding: .day, value: -leading, to: monthInterval.start) ?? monthInterval.start
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    private var visibleRange: DateInterval {
        let days = visibleDays
        let start = days.first ?? store.displayedCalendarMonth
        let end = days.last.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
            ?? calendar.date(byAdding: .month, value: 1, to: store.displayedCalendarMonth) ?? store.displayedCalendarMonth
        return DateInterval(start: start, end: end)
    }

    private var visibleOccurrences: [CalendarOccurrence] {
        cachedOccurrences
    }

    private var renderIdentity: CalendarRenderIdentity {
        CalendarRenderIdentity(
            sourceID: store.selectedCalendarSourceID,
            searchText: store.searchText,
            eventCount: store.calendarEvents.count,
            firstEventID: store.calendarEvents.first?.id,
            lastEventID: store.calendarEvents.last?.id,
            displayedMonth: store.displayedCalendarMonth
        )
    }

    private var monthHeader: some View {
        HStack(spacing: 8) {
            Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .help("Previous month (Command–Left Arrow)")
            Button("Today") {
                let today = calendar.startOfDay(for: Date())
                store.selectedCalendarDate = today
                store.displayedCalendarMonth = calendar.startOfMonth(containing: today)
            }
            .controlSize(.small)
            .keyboardShortcut("t", modifiers: [.command])
            .help("Show today (Command–T)")
            Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .help("Next month (Command–Right Arrow)")
            Spacer()
            Text(store.displayedCalendarMonth, format: .dateTime.month(.wide).year())
                .font(.title3.bold())
            Spacer()
            Text(store.itemResultTotal, format: .number)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .help("Matching events")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private var weekdayHeader: some View {
        LazyVGrid(columns: columns, spacing: 3) {
            ForEach(Array(rotatedWeekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol.uppercased())
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 7)
        .padding(.bottom, 3)
    }

    private var monthGrid: some View {
        LazyVGrid(columns: columns, spacing: 3) {
            ForEach(visibleDays, id: \.self) { day in
                CalendarDayCell(
                    date: day,
                    isInDisplayedMonth: calendar.isDate(day, equalTo: store.displayedCalendarMonth, toGranularity: .month),
                    isSelected: calendar.isDate(day, inSameDayAs: store.selectedCalendarDate),
                    isToday: calendar.isDateInToday(day),
                    occurrences: occurrences(on: day)
                ) {
                    store.selectedCalendarDate = calendar.startOfDay(for: day)
                    if !calendar.isDate(day, equalTo: store.displayedCalendarMonth, toGranularity: .month) {
                        store.displayedCalendarMonth = calendar.startOfMonth(containing: day)
                    }
                }
            }
        }
        .padding(.horizontal, 7)
    }

    private var rotatedWeekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let offset = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
        return Array(symbols[offset...] + symbols[..<offset])
    }

    private func occurrences(on day: Date) -> [CalendarOccurrence] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        return visibleOccurrences.filter { $0.intersects(interval) }
    }

    private func moveMonth(_ value: Int) {
        guard let month = calendar.date(byAdding: .month, value: value, to: store.displayedCalendarMonth) else { return }
        store.displayedCalendarMonth = calendar.startOfMonth(containing: month)
        store.selectedCalendarDate = store.displayedCalendarMonth
    }

    @ToolbarContentBuilder private var exportToolbar: some ToolbarContent {
        if store.isExportingItems { ToolbarItem { ProgressView().controlSize(.small).help("Exporting records") } }
        ToolbarItem {
            Menu {
                Button("Selected Events as iCalendar") { store.exportCalendarEvents(store.selectedCalendarEvents, format: .ics) }
                    .disabled(store.selectedCalendarEvents.isEmpty)
                Button("Selected Events as CSV") { store.exportCalendarEvents(store.selectedCalendarEvents, format: .csv) }
                    .disabled(store.selectedCalendarEvents.isEmpty)
                Divider()
                Button("Loaded Events as iCalendar") { store.exportCalendarEvents(store.calendarEvents, format: .ics) }
                Button("Loaded Events as CSV") { store.exportCalendarEvents(store.calendarEvents, format: .csv) }
                Divider()
                Button("All Matching Events as iCalendar") { store.exportAllMatchingCalendarEvents(format: .ics) }
                Button("All Matching Events as CSV") { store.exportAllMatchingCalendarEvents(format: .csv) }
            } label: { Label("Export Events", systemImage: "square.and.arrow.up") }
            .disabled(store.calendarEvents.isEmpty || store.isExportingItems)
        }
    }
}

struct CalendarDayAgendaView: View {
    @EnvironmentObject private var store: ArchiveStore
    @State private var occurrences: [CalendarOccurrence] = []
    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(store.selectedCalendarDate, format: .dateTime.weekday(.wide).month(.wide).day().year())
                    .font(.headline)
                Spacer()
                Text(occurrences.count, format: .number)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if occurrences.isEmpty {
                ContentUnavailableView("No Events", systemImage: "calendar")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $store.selectedCalendarEventIDs) {
                    ForEach(occurrences) { occurrence in
                        CalendarAgendaRow(occurrence: occurrence)
                            .tag(occurrence.event.id)
                    }
                }
                .listStyle(.inset)
            }
        }
        .task(id: agendaIdentity) {
            guard let range = calendar.dateInterval(of: .day, for: store.selectedCalendarDate) else {
                occurrences = []
                return
            }
            let events = store.calendarEvents
            let workingCalendar = calendar
            let computed = await Task.detached(priority: .userInitiated) {
                CalendarOccurrenceEngine.occurrences(for: events, intersecting: range, calendar: workingCalendar)
            }.value
            guard !Task.isCancelled else { return }
            occurrences = computed
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Events for selected day")
    }

    private var agendaIdentity: CalendarAgendaIdentity {
        CalendarAgendaIdentity(
            sourceID: store.selectedCalendarSourceID,
            searchText: store.searchText,
            eventCount: store.calendarEvents.count,
            firstEventID: store.calendarEvents.first?.id,
            lastEventID: store.calendarEvents.last?.id,
            selectedDate: store.selectedCalendarDate
        )
    }
}

private struct CalendarRenderIdentity: Hashable {
    let sourceID: String?
    let searchText: String
    let eventCount: Int
    let firstEventID: String?
    let lastEventID: String?
    let displayedMonth: Date
}

private struct CalendarAgendaIdentity: Hashable {
    let sourceID: String?
    let searchText: String
    let eventCount: Int
    let firstEventID: String?
    let lastEventID: String?
    let selectedDate: Date
}

private struct CalendarDayCell: View {
    let date: Date
    let isInDisplayedMonth: Bool
    let isSelected: Bool
    let isToday: Bool
    let occurrences: [CalendarOccurrence]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Calendar.current.component(.day, from: date), format: .number)
                    .font(.caption.weight(isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? Color.white : (isInDisplayedMonth ? Color.primary : Color.secondary))
                    .frame(width: 22, height: 22)
                    .background(isToday ? Color.accentColor : .clear, in: Circle())
                ForEach(occurrences.prefix(2)) { occurrence in
                    Text(occurrence.event.title)
                        .font(.system(size: 8, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 2))
                }
                if occurrences.count > 2 {
                    Text("+\(occurrences.count - 2)").font(.system(size: 8)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(3)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.16)) }
            .opacity(isInDisplayedMonth ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityValue("\(occurrences.count) events")
        .accessibilityHint("Selects this date and updates the day agenda")
    }
}

private struct CalendarAgendaRow: View {
    let occurrence: CalendarOccurrence

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Rectangle().fill(Color.accentColor).frame(width: 3).clipShape(Capsule())
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(occurrence.event.title).fontWeight(.medium).lineLimit(1)
                    if occurrence.event.recurrence != nil { Image(systemName: "repeat").font(.caption2).foregroundStyle(.secondary) }
                    if occurrence.event.recurrenceID != nil { Image(systemName: "arrow.triangle.2.circlepath").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(timeLabel)
                    .font(.caption).foregroundStyle(.secondary)
                if !occurrence.event.location.isEmpty {
                    Label(occurrence.event.location, systemImage: "mappin.and.ellipse")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(occurrence.event.title), \(timeLabel)")
    }

    private var timeLabel: String {
        if occurrence.event.isAllDay { return "All day" }
        return "\(occurrence.startAt.formatted(date: .omitted, time: .shortened)) – \(occurrence.endAt.formatted(date: .omitted, time: .shortened))"
    }
}

private extension Calendar {
    func startOfMonth(containing date: Date) -> Date {
        dateInterval(of: .month, for: date)?.start ?? startOfDay(for: date)
    }
}
