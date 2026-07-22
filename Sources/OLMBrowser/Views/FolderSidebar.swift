import SwiftUI

struct FolderSidebar: View {
    @EnvironmentObject private var store: ArchiveStore

    var body: some View {
        List(selection: $store.selectedFolderID) {
            if let snapshot = store.snapshot {
                Section {
                    ArchiveHeader(identity: snapshot.identity)
                }

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
            }
        }
        .listStyle(.sidebar)
        .onChange(of: store.selectedFolderID) {
            store.folderSelectionChanged()
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
