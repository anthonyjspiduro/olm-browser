import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: ArchiveStore

    var body: some View {
        Group {
            if store.snapshot == nil {
                WelcomeView()
            } else {
                BrowserView()
            }
        }
        .alert(
            "Couldn’t Open Archive",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "Unknown error")
        }
        .onOpenURL { url in
            store.open(url)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            store.open(url)
            return true
        } isTargeted: { _ in }
    }
}

private struct BrowserView: View {
    @EnvironmentObject private var store: ArchiveStore
    @State private var showingArchiveInformation = false

    var body: some View {
        NavigationSplitView {
            FolderSidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 310)
        } content: {
            Group {
                switch store.browserMode {
                case .mail: MessageListView()
                case .contacts: ContactListView()
                case .calendar: CalendarWorkspaceMiddleView()
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 370, max: 520)
        } detail: {
            switch store.browserMode {
            case .mail: MessageDetailView()
            case .contacts: ContactDetailView()
            case .calendar: CalendarWorkspaceRightView()
            }
        }
        .navigationTitle(store.snapshot?.identity.displayName ?? "OLM Browser")
        .searchable(
            text: $store.searchText,
            placement: .toolbar,
            prompt: searchPrompt
        )
        .onChange(of: store.searchText) {
            store.searchTextChanged()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.refreshOperationalStatus()
                    showingArchiveInformation.toggle()
                } label: {
                    Label("Archive Information", systemImage: "info.circle")
                }
                .help("Archive information")
                .popover(isPresented: $showingArchiveInformation) {
                    ArchiveInformationView()
                }
            }
        }
    }

    private var searchPrompt: String {
        switch store.browserMode {
        case .mail: "Search entire archive"
        case .contacts: "Search contacts"
        case .calendar: "Search calendar"
        }
    }
}

private struct ArchiveInformationView: View {
    @EnvironmentObject private var store: ArchiveStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Archive Operations").font(.headline)
            if let status = store.operationalStatus {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    row("Archive entries", status.archiveEntries.formatted())
                    row("Message entries", status.messageEntries.formatted())
                    row("Attachment payloads", status.attachmentEntries.formatted())
                    row("Duplicate ZIP paths", status.duplicateEntryPaths.formatted())
                    row("Unreadable messages", status.failedMessageEntries.formatted())
                    row("Recovered malformed messages", status.recoveredMalformedMessageEntries.formatted())
                    row("CRC failures", status.checksumFailureEntries.formatted())
                    row("Unsupported compression", status.unsupportedCompressionEntries.formatted())
                    row("Search cache", ByteCountFormatter.string(fromByteCount: status.cacheByteCount, countStyle: .file))
                    Divider()
                    row("Parsed contact collections", status.itemDiagnostics.parsedContactCollections.formatted())
                    row("Failed contact collections", status.itemDiagnostics.failedContactCollections.formatted())
                    row("Parsed contacts", status.itemDiagnostics.parsedContacts.formatted())
                    row("Distribution lists", status.itemDiagnostics.contactDistributionLists.formatted())
                    row("Parsed calendar collections", status.itemDiagnostics.parsedCalendarCollections.formatted())
                    row("Failed calendar collections", status.itemDiagnostics.failedCalendarCollections.formatted())
                    row("Parsed calendar events", status.itemDiagnostics.parsedCalendarEvents.formatted())
                    row("Unsupported recurrence", status.itemDiagnostics.unsupportedRecurrencePatterns.formatted())
                    row("Recurrence exceptions", status.itemDiagnostics.recurrenceExceptions.formatted())
                    row("Canceled events", status.itemDiagnostics.cancelledCalendarEvents.formatted())
                }
                .font(.callout)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(store.indexProgress.isComplete ? "Search index complete" : "Indexing search")
                ProgressView(value: store.indexProgress.fractionCompleted)
                Text("\(store.indexProgress.indexed.formatted()) of \(store.indexProgress.total.formatted()) entries · \(store.indexProgress.failed.formatted()) unreadable")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                if !store.indexProgress.isComplete {
                    Button("Cancel Indexing") { store.cancelIndexing() }
                }
                Button("Rebuild Index") { store.rebuildSearchIndex() }
                Button("Delete Cache", role: .destructive) { store.deleteSearchCache() }
            }
            Button("Export Diagnostics…") { store.exportDiagnosticReport() }
                .disabled(store.operationalStatus == nil)
                .help("Export aggregate archive and search health metrics without message content")
        }
        .padding(18)
        .frame(width: 420)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow { Text(label).foregroundStyle(.secondary); Text(value).textSelection(.enabled) }
    }
}
