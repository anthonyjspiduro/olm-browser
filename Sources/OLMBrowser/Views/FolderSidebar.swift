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
                        ForEach(snapshot.folders.filter { $0.accountID == account.id }) { folder in
                            FolderRow(folder: folder)
                                .tag(folder.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: store.selectedFolderID) {
            store.selectedMessageID = store.visibleMessages.first?.id
        }
    }
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

    var body: some View {
        HStack(spacing: 8) {
            Label(folder.name, systemImage: folder.kind.symbolName)
                .lineLimit(1)
            Spacer(minLength: 6)
            if folder.unreadCount > 0 {
                Text(folder.unreadCount, format: .number)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .help("\(folder.messageCount.formatted()) messages")
    }
}
