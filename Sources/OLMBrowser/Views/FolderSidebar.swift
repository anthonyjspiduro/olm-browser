import SwiftUI

struct FolderSidebar: View {
    @EnvironmentObject private var store: ArchiveStore

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $store.selectedFolderID) {
                if let snapshot = store.snapshot {
                    Section {
                        ArchiveHeader(identity: snapshot.identity)
                    }

                    switch store.browserMode {
                    case .mail:
                        ForEach(snapshot.accounts) { account in
                            Section(account.displayName) {
                                OutlineGroup(folderTree(for: account.id), children: \.children) { node in
                                    FolderRow(
                                        folder: node.folder,
                                        showsUnreadCount: store.unreadCountsAreAccurate
                                    )
                                        .tag(node.folder.id)
                                }
                            }
                        }
                    case .contacts:
                        Section("Contact Lists") {
                            ForEach(snapshot.contactSources) { source in
                                Button { store.selectedContactSourceID = source.id; store.itemSourceSelectionChanged() } label: {
                                    SourceLabel(source: source, systemImage: "person.2")
                                }
                                .buttonStyle(.plain)
                                .fontWeight(store.selectedContactSourceID == source.id ? .semibold : .regular)
                            }
                            if snapshot.contactSources.isEmpty { ContentUnavailableView("No Contacts", systemImage: "person.crop.circle.badge.xmark") }
                        }
                    case .calendar:
                        Section("Calendars") {
                            Button {
                                store.showsAllCalendarSources = true
                                store.selectedCalendarSourceID = nil
                                store.itemSourceSelectionChanged()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "calendar.badge.plus")
                                    Text("All Calendars")
                                }
                            }
                            .buttonStyle(.plain)
                            .fontWeight(store.showsAllCalendarSources ? .semibold : .regular)

                            ForEach(snapshot.calendarSources) { source in
                                Button {
                                    store.showsAllCalendarSources = false
                                    store.selectedCalendarSourceID = source.id
                                    store.itemSourceSelectionChanged()
                                } label: {
                                    SourceLabel(source: source, systemImage: "calendar")
                                }
                                .buttonStyle(.plain)
                                .fontWeight(store.selectedCalendarSourceID == source.id ? .semibold : .regular)
                            }
                            if snapshot.calendarSources.isEmpty { ContentUnavailableView("No Calendars", systemImage: "calendar.badge.exclamationmark") }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            BrowserModeBar(selection: $store.browserMode)
        }
        .onChange(of: store.selectedFolderID) {
            if store.browserMode == .mail { store.folderSelectionChanged() }
        }
        .onChange(of: store.browserMode) {
            store.browserModeChanged()
        }
    }

    private func folderTree(for accountID: MailAccount.ID) -> [FolderNode] {
        guard let folders = store.snapshot?.folders.filter({ $0.accountID == accountID }) else {
            return []
        }
        func children(of parentID: MailFolder.ID?) -> [FolderNode] {
            folders.filter { $0.parentID == parentID }.map { folder in
                let nested = children(of: folder.id)
                return FolderNode(folder: folder, children: nested.isEmpty ? nil : nested)
            }
        }
        return children(of: nil)
    }
}

private struct BrowserModeBar: View {
    @Binding var selection: BrowserMode

    var body: some View {
        HStack(spacing: 4) {
            ForEach(BrowserMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: mode.symbolName).font(.system(size: 16, weight: .semibold))
                        Text(mode.label).font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(selection == mode ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selection == mode ? Color.accentColor.opacity(0.14) : .clear)
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character(String(BrowserMode.allCases.firstIndex(of: mode)! + 1))), modifiers: .command)
                .accessibilityLabel(mode.label)
                .accessibilityValue(selection == mode ? "Selected" : "")
            }
        }
        .padding(7)
        .background(.bar)
    }
}

private struct SourceLabel: View {
    let source: ArchiveItemSource
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name).lineLimit(1)
                Text(source.accountID ?? "On My Computer")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

private struct FolderNode: Identifiable {
    let folder: MailFolder
    let children: [FolderNode]?
    var id: MailFolder.ID { folder.id }
}

private struct ArchiveHeader: View {
    let identity: ArchiveIdentity

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(identity.displayName)
                .font(.headline)
                .lineLimit(2)
            Text(identity.formattedSize)
                .font(.caption)
                .foregroundStyle(.secondary)

            if identity.isPreviewData {
                Label("Interface preview", systemImage: "paintbrush")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.top, 3)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct FolderRow: View {
    let folder: MailFolder
    let showsUnreadCount: Bool

    var body: some View {
        HStack(spacing: 8) {
            Label(folder.name, systemImage: folder.kind.symbolName)
                .lineLimit(1)
            Spacer(minLength: 6)
            if showsUnreadCount && folder.unreadCount > 0 {
                Text(folder.unreadCount, format: .number)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .help(showsUnreadCount
              ? "\(folder.messageCount.formatted()) messages · \(folder.unreadCount.formatted()) unread"
              : "\(folder.messageCount.formatted()) messages · unread total available after indexing")
    }
}
