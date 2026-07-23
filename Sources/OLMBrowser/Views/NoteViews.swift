import SwiftUI

struct NoteListView: View {
    @EnvironmentObject private var store: ArchiveStore

    var body: some View {
        List(selection: $store.selectedNoteIDs) {
            ForEach(store.notes) { note in
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.title)
                        .fontWeight(.medium)
                        .lineLimit(2)
                    Text(note.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let date = note.modifiedAt ?? note.createdAt {
                        Text(date, format: .dateTime.year().month().day())
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
                .tag(note.id)
                .onAppear { store.itemDidAppear(note.id) }
            }
            if store.isLoadingItems {
                HStack { Spacer(); ProgressView(); Spacer() }.padding()
            }
        }
        .overlay {
            if store.isLoadingItems && store.notes.isEmpty {
                ArchiveItemLoadingView()
            } else if !store.isLoadingItems && store.notes.isEmpty {
                ContentUnavailableView(
                    "No Notes",
                    systemImage: "note.text",
                    description: Text("This notes collection contains no matching records.")
                )
            }
        }
        .toolbar {
            if store.isExportingItems {
                ToolbarItem {
                    ProgressView().controlSize(.small).help("Exporting notes")
                }
            }
            ToolbarItem {
                Menu {
                    exportButtons(label: "Selected Notes", records: store.selectedNotes)
                    Divider()
                    exportButtons(label: "Loaded Notes", records: store.notes)
                    Divider()
                    ForEach(NoteExportFormat.allCases) { format in
                        Button("All Matching Notes as \(format.label)") {
                            store.exportAllMatchingNotes(format: format)
                        }
                    }
                } label: {
                    Label("Export Notes", systemImage: "square.and.arrow.up")
                }
                .disabled(store.notes.isEmpty || store.isExportingItems)
            }
        }
    }

    @ViewBuilder
    private func exportButtons(label: String, records: [NoteRecord]) -> some View {
        ForEach(NoteExportFormat.allCases) { format in
            Button("\(label) as \(format.label)") {
                store.exportNotes(records, format: format)
            }
            .disabled(records.isEmpty)
        }
    }
}

struct NoteDetailView: View {
    @EnvironmentObject private var store: ArchiveStore

    var body: some View {
        if store.selectedNotes.count > 1 {
            VStack(spacing: 14) {
                Image(systemName: "note.text")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("\(store.selectedNotes.count.formatted()) Notes Selected")
                    .font(.title2.bold())
                HStack {
                    ForEach(NoteExportFormat.allCases) { format in
                        Button("Export \(format.label)") {
                            store.exportNotes(store.selectedNotes, format: format)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let note = store.selectedNote {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(note.title)
                                .font(.largeTitle.bold())
                                .textSelection(.enabled)
                            if let created = note.createdAt {
                                Label(
                                    "Created \(created.formatted(date: .long, time: .shortened))",
                                    systemImage: "calendar.badge.plus"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            if let modified = note.modifiedAt {
                                Label(
                                    "Modified \(modified.formatted(date: .long, time: .shortened))",
                                    systemImage: "clock"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Menu {
                            ForEach(NoteExportFormat.allCases) { format in
                                Button(format.label) {
                                    store.exportNotes([note], format: format)
                                }
                            }
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                    }
                    Divider()
                    Text(note.text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(28)
                .frame(maxWidth: 900, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Select a Note", systemImage: "note.text")
        }
    }
}
