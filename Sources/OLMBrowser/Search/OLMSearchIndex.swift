import CSQLite
import Foundation

enum SearchIndexError: LocalizedError {
    case openFailed(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): "Could not open the search index: \(message)"
        case .operationFailed(let message): "Search index operation failed: \(message)"
        }
    }
}

/// Disposable, archive-specific SQLite/FTS5 index. It contains derived text
/// only; deleting the database never affects the source OLM.
final class OLMSearchIndex: @unchecked Sendable {
    private var database: OpaquePointer?
    private var insertStatement: OpaquePointer?
    private let lock = NSLock()

    init(archiveURL: URL, fileSize: Int64, modifiedAt: Date?) throws {
        let cacheRoot = try Self.cacheDirectory()
        let fingerprint = Self.fingerprint(
            "\(archiveURL.standardizedFileURL.path)|\(fileSize)|\(modifiedAt?.timeIntervalSince1970 ?? 0)"
        )
        let databaseURL = cacheRoot.appendingPathComponent("\(fingerprint).sqlite")

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close(handle) }
            throw SearchIndexError.openFailed(message)
        }
        database = handle

        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=NORMAL;")
        try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        try execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS message_search USING fts5(
                entry_path UNINDEXED,
                subject,
                sender,
                recipients,
                preview,
                body,
                attachments,
                tokenize='unicode61 remove_diacritics 2'
            );
            """)

        let insertSQL = """
            INSERT INTO message_search
                (entry_path, subject, sender, recipients, preview, body, attachments)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
        guard sqlite3_prepare_v2(handle, insertSQL, -1, &insertStatement, nil) == SQLITE_OK else {
            throw SearchIndexError.operationFailed(String(cString: sqlite3_errmsg(handle)))
        }
    }

    deinit {
        if let insertStatement { sqlite3_finalize(insertStatement) }
        if let database { sqlite3_close(database) }
    }

    var nextEntryOffset: Int {
        lock.withLock { Int(metadataValue(for: "next_entry_offset") ?? "0") ?? 0 }
    }

    var isComplete: Bool {
        lock.withLock { metadataValue(for: "complete") == "1" }
    }

    func beginBatch() throws {
        try lock.withLock { try execute("BEGIN IMMEDIATE TRANSACTION;") }
    }

    func insert(_ message: MessageSummary, entryPath: String) throws {
        try lock.withLock {
            guard let database, let statement = insertStatement else {
                throw SearchIndexError.operationFailed("database is closed")
            }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            let attachmentNames = message.attachments.map(\.filename).joined(separator: " ")
            let values = [
                entryPath,
                message.subject,
                "\(message.sender.label) \(message.sender.address)",
                message.recipients.map { "\($0.label) \($0.address)" }.joined(separator: " "),
                message.preview,
                message.body,
                attachmentNames
            ]
            for (index, value) in values.enumerated() {
                sqlite3_bind_text(statement, Int32(index + 1), value, -1, Self.transient)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SearchIndexError.operationFailed(String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    func commitBatch(nextOffset: Int, complete: Bool) throws {
        try lock.withLock {
            try setMetadataValue(String(nextOffset), for: "next_entry_offset")
            try setMetadataValue(complete ? "1" : "0", for: "complete")
            try execute("COMMIT;")
        }
    }

    func rollbackBatch() {
        lock.withLock { try? execute("ROLLBACK;") }
    }

    func searchPaths(matching query: String, limit: Int) throws -> [String] {
        try lock.withLock {
            guard let database else { return [] }
            let expression = Self.ftsExpression(for: query)
            guard !expression.isEmpty else { return [] }
            let sql = "SELECT entry_path FROM message_search WHERE message_search MATCH ? ORDER BY rank LIMIT ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw SearchIndexError.operationFailed(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, expression, -1, Self.transient)
            sqlite3_bind_int(statement, 2, Int32(limit))

            var paths: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let text = sqlite3_column_text(statement, 0) {
                    paths.append(String(cString: text))
                }
            }
            return paths
        }
    }

    private func metadataValue(for key: String) -> String? {
        guard let database else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM metadata WHERE key = ?;", -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    private func setMetadataValue(_ value: String, for key: String) throws {
        guard let database else { return }
        let sql = "INSERT INTO metadata (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SearchIndexError.operationFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, Self.transient)
        sqlite3_bind_text(statement, 2, value, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SearchIndexError.operationFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func execute(_ sql: String) throws {
        guard let database else { return }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(error)
            throw SearchIndexError.operationFailed(message)
        }
    }

    private static func cacheDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("OLMBrowser/Search", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func ftsExpression(for query: String) -> String {
        query.split(whereSeparator: \.isWhitespace)
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " AND ")
    }

    private static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
