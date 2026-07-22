import SwiftUI

struct MessageListView: View {
    @EnvironmentObject private var store: ArchiveStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.searchText.isEmpty ? (store.selectedFolder?.name ?? "All Messages") : "Search Results")
                        .font(.headline)
                    Text(resultLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu("Export Loaded") {
                    ForEach(MessageExportFormat.allCases) { format in
                        Button(format.label) { store.exportLoadedMessages(format: format) }
                    }
                }
                .disabled(store.visibleMessages.isEmpty)
                .help("Export the messages currently loaded in this list")
                if !store.searchText.isEmpty {
                    Toggle("This Folder", isOn: $store.isSearchFolderScoped)
                        .toggleStyle(.checkbox)
                        .onChange(of: store.isSearchFolderScoped) { store.searchOptionsChanged() }
                    Picker("Sort", selection: $store.searchSort) {
                        ForEach(SearchSort.allCases) { sort in Text(sort.label).tag(sort) }
                    }
                    .labelsHidden()
                    .frame(width: 125)
                    .onChange(of: store.searchSort) { store.searchOptionsChanged() }
                }
                if !store.indexProgress.isComplete {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("Indexing search")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ProgressView(value: store.indexProgress.fractionCompleted)
                            .frame(width: 90)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if store.isSearching || (store.isLoadingPage && store.visibleMessages.isEmpty) {
                ProgressView(store.isSearching ? "Searching archive…" : "Loading messages…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.visibleMessages.isEmpty {
                ContentUnavailableView.search(text: store.searchText)
            } else {
                List(store.visibleMessages, selection: $store.selectedMessageID) { message in
                    MessageRow(message: message)
                        .tag(message.id)
                        .onAppear {
                            if message.id == store.visibleMessages.last?.id, store.hasMoreMessages {
                                store.loadNextPage()
                            }
                        }
                }
                .listStyle(.inset)
                .safeAreaInset(edge: .bottom) {
                    if store.isLoadingPage && !store.messages.isEmpty {
                        ProgressView("Loading more…")
                            .font(.caption)
                            .padding(8)
                            .frame(maxWidth: .infinity)
                            .background(.bar)
                    }
                }
            }
        }
    }

    private var resultLabel: String {
        let count = store.visibleMessages.count
        if store.snapshot?.identity.isPreviewData == true {
            return "\(count) preview \(count == 1 ? "message" : "messages")"
        }
        if !store.searchText.isEmpty {
            let suffix = store.indexProgress.isComplete ? "" : " · index still building"
            let total = store.searchResultTotal
            let prefix = total > count ? "Showing \(count.formatted()) of \(total.formatted())" : "\(count.formatted()) results"
            return "\(prefix)\(suffix)"
        }
        if store.searchText.isEmpty,
           let total = store.selectedFolder?.messageCount,
           total > count {
            let suffix = store.indexProgress.isComplete ? "" : " · chronological order finalizes after indexing"
            return "Showing \(count.formatted()) of \(total.formatted())\(suffix)"
        }
        return "\(count) \(count == 1 ? "message" : "messages")"
    }
}

private struct MessageRow: View {
    let message: MessageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Circle()
                    .fill(message.isRead ? Color.clear : Color.accentColor)
                    .frame(width: 7, height: 7)
                Text(message.sender.label)
                    .fontWeight(message.isRead ? .regular : .semibold)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(message.sentAt, format: .dateTime.month(.abbreviated).day())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Text(message.subject)
                    .fontWeight(message.isRead ? .regular : .semibold)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if message.isFlagged {
                    Image(systemName: "flag.fill")
                        .foregroundStyle(.orange)
                }
                if !message.attachments.isEmpty {
                    Image(systemName: "paperclip")
                        .foregroundStyle(.secondary)
                }
            }

            Text(message.preview)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 6)
    }
}
