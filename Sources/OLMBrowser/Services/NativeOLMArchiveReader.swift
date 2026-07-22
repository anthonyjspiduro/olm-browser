import Foundation

/// First production reader milestone. It catalogs the archive in place and
/// loads a bounded sample from each folder. Paging and the persistent FTS index
/// will replace the per-folder bound in the next milestone.
struct NativeOLMArchiveReader: OLMArchiveReading {
    private let messageLimitPerFolder = 40

    func openArchive(at url: URL) throws -> ArchiveSnapshot {
        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .isReadableKey])
        guard resourceValues.isReadable != false else {
            throw ArchiveReaderError.unreadableArchive
        }

        let archive = try ZIPArchive(url: url)
        let catalog = buildCatalog(entries: archive.entries)
        guard !catalog.messageEntriesByFolder.isEmpty else {
            throw ArchiveReaderError.noMessagesFound
        }

        let accounts = catalog.accountAddresses.sorted().map {
            MailAccount(id: $0, displayName: $0, address: $0)
        }
        let folders = makeFolders(from: catalog)
        let parser = OLMMessageParser()
        var messages: [MessageSummary] = []

        for folder in folders {
            let entries = catalog.messageEntriesByFolder[folder.id, default: []]
                .suffix(messageLimitPerFolder)
            for entry in entries {
                autoreleasepool {
                    guard let data = try? archive.data(for: entry, maximumSize: 32 * 1_024 * 1_024),
                          let message = parser.parse(
                            data: data,
                            entryPath: entry.path,
                            folderID: folder.id
                          ) else { return }
                    messages.append(message)
                }
            }
        }
        messages.sort { $0.sentAt > $1.sentAt }

        return ArchiveSnapshot(
            identity: ArchiveIdentity(
                url: url,
                displayName: url.lastPathComponent,
                size: Int64(resourceValues.fileSize ?? 0),
                isPreviewData: false
            ),
            accounts: accounts,
            folders: folders,
            messages: messages
        )
    }

    private func buildCatalog(entries: [ZIPEntry]) -> Catalog {
        var catalog = Catalog()
        let marker = "/com.microsoft.__Messages/"

        for entry in entries where entry.path.hasSuffix(".xml") {
            guard entry.path.hasPrefix("Accounts/"),
                  let markerRange = entry.path.range(of: marker),
                  entry.path[markerRange.upperBound...].lastPathComponent.hasPrefix("message_") else {
                continue
            }

            let accountStart = entry.path.index(entry.path.startIndex, offsetBy: "Accounts/".count)
            let account = String(entry.path[accountStart..<markerRange.lowerBound])
            let remainder = String(entry.path[markerRange.upperBound...])
            let components = remainder.split(separator: "/").map(String.init)
            guard components.count >= 2 else { continue }
            let folderPath = components.dropLast().joined(separator: "/")
            let folderID = Self.folderID(account: account, path: folderPath)

            catalog.accountAddresses.insert(account)
            catalog.folderPathsByAccount[account, default: []].insert(folderPath)
            catalog.messageEntriesByFolder[folderID, default: []].append(entry)

            var ancestors = folderPath.split(separator: "/").map(String.init)
            while ancestors.count > 1 {
                ancestors.removeLast()
                catalog.folderPathsByAccount[account, default: []]
                    .insert(ancestors.joined(separator: "/"))
            }
        }
        return catalog
    }

    private func makeFolders(from catalog: Catalog) -> [MailFolder] {
        var result: [MailFolder] = []
        for account in catalog.accountAddresses.sorted() {
            for path in catalog.folderPathsByAccount[account, default: []].sorted() {
                let components = path.split(separator: "/").map(String.init)
                let name = components.last ?? path
                let parentPath = components.dropLast().joined(separator: "/")
                let id = Self.folderID(account: account, path: path)
                let count = catalog.messageEntriesByFolder[id, default: []].count
                result.append(MailFolder(
                    id: id,
                    accountID: account,
                    parentID: parentPath.isEmpty ? nil : Self.folderID(account: account, path: parentPath),
                    name: name,
                    kind: Self.folderKind(name),
                    messageCount: count,
                    unreadCount: 0
                ))
            }
        }

        return result.sorted {
            let leftRank = Self.folderRank($0.kind)
            let rightRank = Self.folderRank($1.kind)
            return leftRank == rightRank
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : leftRank < rightRank
        }
    }

    private static func folderID(account: String, path: String) -> String {
        "\(account)::\(path)"
    }

    private static func folderKind(_ name: String) -> FolderKind {
        switch name.lowercased() {
        case "inbox": .inbox
        case "sent", "sent items": .sent
        case "drafts": .drafts
        case "deleted", "deleted items", "trash": .deleted
        case "archive": .archive
        default: .custom
        }
    }

    private static func folderRank(_ kind: FolderKind) -> Int {
        switch kind {
        case .inbox: 0
        case .sent: 1
        case .drafts: 2
        case .archive: 3
        case .deleted: 4
        case .custom: 5
        }
    }
}

private struct Catalog {
    var accountAddresses: Set<String> = []
    var folderPathsByAccount: [String: Set<String>] = [:]
    var messageEntriesByFolder: [String: [ZIPEntry]] = [:]
}

private extension String.SubSequence {
    var lastPathComponent: Substring {
        split(separator: "/").last ?? self
    }
}
