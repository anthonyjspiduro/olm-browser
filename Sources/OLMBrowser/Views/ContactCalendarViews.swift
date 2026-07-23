import AppKit
import SwiftUI

struct ContactListView: View {
    @EnvironmentObject private var store: ArchiveStore

    var body: some View {
        List(selection: $store.selectedContactIDs) {
            ForEach(store.contacts) { contact in
                HStack(spacing: 10) {
                    ContactAvatar(contact: contact, size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(contact.displayName).fontWeight(.medium).lineLimit(1)
                        Text(contact.emails.first?.address ?? contact.company)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
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
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .center, spacing: 18) {
                        ContactAvatar(contact: contact, size: 84)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(contact.displayName).font(.largeTitle.bold()).textSelection(.enabled)
                            if !contact.jobTitle.isEmpty || !contact.company.isEmpty {
                                Text([contact.jobTitle, contact.company].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.title3).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        Spacer()
                        Menu {
                            Button("vCard") { store.exportContacts([contact], format: .vcf) }
                            Button("CSV") { store.exportContacts([contact], format: .csv) }
                        } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    }

                    if !contact.emails.isEmpty {
                        ContactInformationCard(title: "Email", systemImage: "envelope.fill") {
                            ForEach(contact.emails) { email in
                                ContactValueRow(label: email.label, value: email.address, systemImage: "envelope")
                            }
                        }
                    }
                    if !contact.phoneNumbers.isEmpty {
                        ContactInformationCard(title: "Phone", systemImage: "phone.fill") {
                            ForEach(contact.phoneNumbers) { phone in
                                ContactValueRow(label: phone.label, value: phone.number, systemImage: "phone")
                            }
                        }
                    }
                    if !contact.postalAddresses.isEmpty {
                        ContactInformationCard(title: "Address", systemImage: "house.fill") {
                            ForEach(contact.postalAddresses) { address in
                                ContactValueRow(
                                    label: address.label,
                                    value: address.formatted,
                                    systemImage: "mappin.and.ellipse"
                                )
                            }
                        }
                    }
                    if contact.birthday != nil || !contact.categories.isEmpty {
                        ContactInformationCard(title: "Additional", systemImage: "person.text.rectangle") {
                            if let birthday = contact.birthday {
                                ContactValueRow(
                                    label: "Birthday",
                                    value: birthday.formatted(date: .long, time: .omitted),
                                    systemImage: "gift"
                                )
                            }
                            if !contact.categories.isEmpty {
                                ContactValueRow(
                                    label: "Groups",
                                    value: contact.categories.joined(separator: ", "),
                                    systemImage: "tag"
                                )
                            }
                        }
                    }
                    if !contact.notes.isEmpty {
                        ContactInformationCard(title: "Notes", systemImage: "note.text") {
                            Text(contact.notes)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let modified = contact.modifiedAt {
                        Label("Last modified \(modified.formatted(date: .long, time: .shortened))", systemImage: "clock")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(28)
                .frame(maxWidth: 820, alignment: .leading)
            }
        } else { ContentUnavailableView("Select a Contact", systemImage: "person.crop.circle") }
    }
}

private struct ContactAvatar: View {
    let contact: ContactRecord
    let size: CGFloat

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.62)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                in: Circle()
            )
            .overlay { Circle().stroke(.white.opacity(0.28), lineWidth: 1) }
            .accessibilityHidden(true)
    }

    private var initials: String {
        let components = contact.displayName.split(whereSeparator: \.isWhitespace)
        let letters = [components.first?.first, components.count > 1 ? components.last?.first : nil]
            .compactMap { $0 }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

private struct ContactInformationCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage).font(.headline)
            Divider()
            content
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.45)) }
    }
}

private struct ContactValueRow: View {
    let label: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            Text(label.isEmpty ? "Other" : label.capitalized)
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(value).textSelection(.enabled)
                .accessibilityLabel(label.isEmpty ? value : "\(label), \(value)")
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless)
            .help("Copy")
            .accessibilityLabel("Copy \(label)")
        }
    }
}

struct CalendarWorkspaceMiddleView: View {
    var body: some View {
        VSplitView {
            CalendarDayAgendaView()
                .frame(minHeight: 150, idealHeight: 230, maxHeight: 280)
            CalendarEventDetailView()
                .frame(minHeight: 320, maxHeight: .infinity)
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
                    if event.isCancelled { Label("Canceled", systemImage: "xmark.circle.fill").foregroundStyle(.red) }
                    if event.isPrivate { Label("Marked private", systemImage: "lock").foregroundStyle(.secondary) }
                    if !event.status.isEmpty && !event.isCancelled { labeled("Status", event.status) }
                    if !event.timeZoneIdentifier.isEmpty { labeled("Time Zone", event.timeZoneIdentifier) }
                    if let recurrenceID = event.recurrenceID {
                        labeled("Recurrence Exception", recurrenceID.formatted(date: .long, time: .shortened))
                    }
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
