import SwiftUI

struct ContactListView: View {
    @EnvironmentObject private var store: ArchiveStore

    var body: some View {
        List(selection: $store.selectedContactIDs) {
            ForEach(store.contacts) { contact in
                VStack(alignment: .leading, spacing: 4) {
                    Text(contact.displayName).fontWeight(.medium).lineLimit(1)
                    Text(contact.emails.first?.address ?? contact.company)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .tag(contact.id)
                .onAppear { store.itemDidAppear(contact.id) }
            }
            if store.isLoadingItems {
                HStack { Spacer(); ProgressView(); Spacer() }.padding()
            }
        }
        .overlay {
            if !store.isLoadingItems && store.contacts.isEmpty {
                ContentUnavailableView("No Contacts", systemImage: "person.crop.circle", description: Text("This contact list contains no matching records."))
            }
        }
        .toolbar {
            if store.isExportingItems { ToolbarItem { ProgressView().controlSize(.small).help("Exporting records") } }
            ToolbarItem {
                Menu {
                    Button("Selected Contacts as vCard") { store.exportContacts(store.selectedContacts, format: .vcf) }
                        .disabled(store.selectedContacts.isEmpty)
                    Button("Selected Contacts as CSV") { store.exportContacts(store.selectedContacts, format: .csv) }
                        .disabled(store.selectedContacts.isEmpty)
                    Divider()
                    Button("Loaded Contacts as vCard") { store.exportContacts(store.contacts, format: .vcf) }
                    Button("Loaded Contacts as CSV") { store.exportContacts(store.contacts, format: .csv) }
                    Divider()
                    Button("All Matching Contacts as vCard") { store.exportAllMatchingContacts(format: .vcf) }
                    Button("All Matching Contacts as CSV") { store.exportAllMatchingContacts(format: .csv) }
                } label: { Label("Export Contacts", systemImage: "square.and.arrow.up") }
                .disabled(store.contacts.isEmpty || store.isExportingItems)
            }
        }
    }
}

struct ContactDetailView: View {
    @EnvironmentObject private var store: ArchiveStore

    var body: some View {
        if store.selectedContacts.count > 1 {
            VStack(spacing: 14) {
                Image(systemName: "person.2.fill").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("\(store.selectedContacts.count.formatted()) Contacts Selected").font(.title2.bold())
                HStack {
                    Button("Export vCard") { store.exportContacts(store.selectedContacts, format: .vcf) }
                    Button("Export CSV") { store.exportContacts(store.selectedContacts, format: .csv) }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let contact = store.selectedContact {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        Image(systemName: "person.crop.circle.fill").font(.system(size: 48)).foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(contact.displayName).font(.title2.bold()).textSelection(.enabled)
                            if !contact.jobTitle.isEmpty || !contact.company.isEmpty {
                                Text([contact.jobTitle, contact.company].filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Menu("Export") {
                            Button("vCard") { store.exportContacts([contact], format: .vcf) }
                            Button("CSV") { store.exportContacts([contact], format: .csv) }
                        }
                    }
                    detailSection("Email Addresses", rows: contact.emails.map { ($0.label, $0.address) })
                    detailSection("Phone Numbers", rows: contact.phoneNumbers.map { ($0.label, $0.number) })
                    if !contact.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Notes").font(.headline)
                            Text(contact.notes).textSelection(.enabled)
                        }
                    }
                }.padding(24).frame(maxWidth: 760, alignment: .leading)
            }
        } else { ContentUnavailableView("Select a Contact", systemImage: "person.crop.circle") }
    }

    @ViewBuilder private func detailSection(_ title: String, rows: [(String, String)]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow { Text(row.0).foregroundStyle(.secondary); Text(row.1).textSelection(.enabled) }
                    }
                }
            }
        }
    }
}

struct CalendarEventListView: View {
    @EnvironmentObject private var store: ArchiveStore

    var body: some View {
        List(selection: $store.selectedCalendarEventIDs) {
            ForEach(store.calendarEvents) { event in
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title).fontWeight(.medium).lineLimit(1)
                    Text(event.startAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(event.id)
                .onAppear { store.itemDidAppear(event.id) }
            }
            if store.isLoadingItems { HStack { Spacer(); ProgressView(); Spacer() }.padding() }
        }
        .overlay {
            if !store.isLoadingItems && store.calendarEvents.isEmpty {
                ContentUnavailableView("No Events", systemImage: "calendar", description: Text("This calendar contains no matching records."))
            }
        }
        .toolbar {
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
}

struct CalendarEventDetailView: View {
    @EnvironmentObject private var store: ArchiveStore

    var body: some View {
        if store.selectedCalendarEvents.count > 1 {
            VStack(spacing: 14) {
                Image(systemName: "calendar.badge.checkmark").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("\(store.selectedCalendarEvents.count.formatted()) Events Selected").font(.title2.bold())
                HStack {
                    Button("Export iCalendar") { store.exportCalendarEvents(store.selectedCalendarEvents, format: .ics) }
                    Button("Export CSV") { store.exportCalendarEvents(store.selectedCalendarEvents, format: .csv) }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let event = store.selectedCalendarEvent {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(event.title).font(.title2.bold()).textSelection(.enabled)
                            Label(dateRange(event), systemImage: "calendar")
                            if !event.location.isEmpty { Label(event.location, systemImage: "mappin.and.ellipse").textSelection(.enabled) }
                        }
                        Spacer()
                        Menu("Export") {
                            Button("iCalendar") { store.exportCalendarEvents([event], format: .ics) }
                            Button("CSV") { store.exportCalendarEvents([event], format: .csv) }
                        }
                    }
                    if event.isPrivate { Label("Marked private", systemImage: "lock").foregroundStyle(.secondary) }
                    if !event.organizer.isEmpty { labeled("Organizer", event.organizer) }
                    if !event.attendees.isEmpty { labeled("Attendees", event.attendees.map { $0.name.isEmpty ? $0.address : $0.name }.joined(separator: "\n")) }
                    if let recurrence = event.recurrence { labeled("Recurrence", [recurrence.frequency, "every \(recurrence.interval)"].filter { !$0.isEmpty }.joined(separator: " · ")) }
                    if !event.details.isEmpty { labeled("Details", event.details) }
                }.padding(24).frame(maxWidth: 820, alignment: .leading)
            }
        } else { ContentUnavailableView("Select an Event", systemImage: "calendar") }
    }

    private func dateRange(_ event: CalendarEventRecord) -> String {
        let start = event.startAt.formatted(date: .long, time: event.isAllDay ? .omitted : .shortened)
        let end = event.endAt.formatted(date: .long, time: event.isAllDay ? .omitted : .shortened)
        return start == end ? start : "\(start) – \(end)"
    }
    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(value).textSelection(.enabled) }
    }
}
