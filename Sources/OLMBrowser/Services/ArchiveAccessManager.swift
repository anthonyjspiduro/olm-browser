import Foundation

struct RecentArchive: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let url: URL
}

/// Stores security-scoped bookmarks in user preferences. Bookmarks are local
/// access grants only; they are never written into the archive or application bundle.
final class ArchiveAccessManager {
    private struct StoredBookmark: Codable {
        let id: String
        let bookmark: Data
        let isSecurityScoped: Bool
    }

    private let defaults: UserDefaults
    private let key = "recentArchiveSecurityBookmarks.v1"
    private let maximumRecentCount = 8
    private var stored: [StoredBookmark]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        stored = (defaults.data(forKey: key))
            .flatMap { try? PropertyListDecoder().decode([StoredBookmark].self, from: $0) } ?? []
    }

    var recentArchives: [RecentArchive] {
        stored.compactMap { item in
            guard let url = resolve(item)?.url else { return nil }
            return RecentArchive(id: item.id, displayName: url.lastPathComponent, url: url)
        }
    }

    func resolveRecent(id: String) -> URL? {
        guard let item = stored.first(where: { $0.id == id }),
              let resolved = resolve(item) else { return nil }
        if resolved.isStale { remember(resolved.url) }
        return resolved.url
    }

    func remember(_ url: URL) {
        let data: Data
        let isSecurityScoped: Bool
        if let scoped = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.fileSizeKey, .contentModificationDateKey],
            relativeTo: nil
        ) {
            data = scoped
            isSecurityScoped = true
        } else if let regular = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: [.fileSizeKey, .contentModificationDateKey],
            relativeTo: nil
        ) {
            data = regular
            isSecurityScoped = false
        } else {
            return
        }
        let id = Self.identity(for: url)
        stored.removeAll { $0.id == id }
        stored.insert(StoredBookmark(id: id, bookmark: data, isSecurityScoped: isSecurityScoped), at: 0)
        if stored.count > maximumRecentCount {
            stored.removeLast(stored.count - maximumRecentCount)
        }
        persist()
    }

    func forget(id: String) {
        stored.removeAll { $0.id == id }
        persist()
    }

    private func resolve(_ item: StoredBookmark) -> (url: URL, isStale: Bool)? {
        var isStale = false
        var options: URL.BookmarkResolutionOptions = [.withoutUI]
        if item.isSecurityScoped {
            options.insert(.withSecurityScope)
        }
        guard let url = try? URL(
            resolvingBookmarkData: item.bookmark,
            options: options,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return (url, isStale)
    }

    private func persist() {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        defaults.set(try? encoder.encode(stored), forKey: key)
    }

    private static func identity(for url: URL) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in url.standardizedFileURL.path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
