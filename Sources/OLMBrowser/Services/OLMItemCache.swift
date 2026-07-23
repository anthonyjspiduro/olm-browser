import Foundation

/// Disposable archive-specific cache for parsed contacts and calendar events.
/// The source OLM remains authoritative and is never modified.
final class OLMItemCache: @unchecked Sendable {
    private static let schemaVersion = 2
    private let directoryURL: URL
    private let lock = NSLock()

    init(
        archiveURL: URL,
        fileSize: Int64,
        modifiedAt: Date?,
        cacheRoot: URL? = nil
    ) throws {
        let root = cacheRoot ?? Self.defaultCacheRoot()
        let archiveIdentity = [
            archiveURL.standardizedFileURL.path,
            String(fileSize),
            String(modifiedAt?.timeIntervalSince1970 ?? 0)
        ].joined(separator: "|")
        directoryURL = root.appendingPathComponent(Self.fingerprint(archiveIdentity), isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func contacts(for sourceID: String) -> [ContactRecord]? {
        load(ContactEnvelope.self, kind: "contacts", sourceID: sourceID)?.records
    }

    func calendarEvents(for sourceID: String) -> [CalendarEventRecord]? {
        load(CalendarEnvelope.self, kind: "calendar", sourceID: sourceID)?.records
    }

    func storeContacts(_ records: [ContactRecord], sourceID: String) {
        store(ContactEnvelope(schemaVersion: Self.schemaVersion, sourceID: sourceID, records: records),
              kind: "contacts", sourceID: sourceID)
    }

    func storeCalendarEvents(_ records: [CalendarEventRecord], sourceID: String) {
        store(CalendarEnvelope(schemaVersion: Self.schemaVersion, sourceID: sourceID, records: records),
              kind: "calendar", sourceID: sourceID)
    }

    var byteCount: Int64 {
        lock.withLock {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directoryURL, includingPropertiesForKeys: [.fileSizeKey]
            ) else { return 0 }
            return urls.reduce(0) {
                $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
    }

    func removeAll() throws {
        try lock.withLock {
            let manager = FileManager.default
            if manager.fileExists(atPath: directoryURL.path) {
                try manager.removeItem(at: directoryURL)
            }
            try manager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    private func load<Envelope: Decodable>(
        _ type: Envelope.Type,
        kind: String,
        sourceID: String
    ) -> Envelope? {
        lock.withLock {
            let url = cacheURL(kind: kind, sourceID: sourceID)
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  let envelope = try? PropertyListDecoder().decode(type, from: data) else {
                return nil
            }
            if let contact = envelope as? ContactEnvelope {
                guard contact.schemaVersion == Self.schemaVersion, contact.sourceID == sourceID else { return nil }
            } else if let calendar = envelope as? CalendarEnvelope {
                guard calendar.schemaVersion == Self.schemaVersion, calendar.sourceID == sourceID else { return nil }
            }
            return envelope
        }
    }

    private func store<Envelope: Encodable>(_ envelope: Envelope, kind: String, sourceID: String) {
        lock.withLock {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            guard let data = try? encoder.encode(envelope) else { return }
            try? data.write(to: cacheURL(kind: kind, sourceID: sourceID), options: .atomic)
        }
    }

    private func cacheURL(kind: String, sourceID: String) -> URL {
        directoryURL.appendingPathComponent("\(kind)-\(Self.fingerprint(sourceID)).plist")
    }

    private static func defaultCacheRoot() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("OLMBrowser/Items", isDirectory: true)
    }

    private static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

private struct ContactEnvelope: Codable {
    let schemaVersion: Int
    let sourceID: String
    let records: [ContactRecord]
}

private struct CalendarEnvelope: Codable {
    let schemaVersion: Int
    let sourceID: String
    let records: [CalendarEventRecord]
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
