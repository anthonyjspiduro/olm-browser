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
    private var listInsertStatement: OpaquePointer?
    private let lock = NSLock()
    private let databaseURL: URL

    init(archiveURL: URL, fileSize: Int64, modifiedAt: Date?) throws {
        let cacheRoot = try Self.cacheDirectory()
        let fingerprint = Self.fingerprint(
            "\(archiveURL.standardizedFileURL.path)|\(fileSize)|\(modifiedAt?.timeIntervalSince1970 ?? 0)"
        )
        let databaseURL = cacheRoot.appendingPathComponent("\(fingerprint).sqlite")
        self.databaseURL = databaseURL

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
        let existingSchema = metadataValue(for: "schema_version")
        if existingSchema != "5" && existingSchema != "6" {
            try execute("DROP TABLE IF EXISTS message_search;")
            try execute("DROP TABLE IF EXISTS message_list;")
            try setMetadataValue("0", for: "next_entry_offset")
            try setMetadataValue("0", for: "complete")
        }
        try execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS message_search USING fts5(
                entry_path UNINDEXED,
                folder_id UNINDEXED,
                sent_at UNINDEXED,
                has_attachment UNINDEXED,
                is_read UNINDEXED,
                subject,
                sender,
                recipients,
                cc_recipients,
                bcc_recipients,
                preview,
                body,
                attachments,
                tokenize='unicode61 remove_diacritics 2'
            );
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS message_list (
                entry_path TEXT PRIMARY KEY,
                folder_id TEXT NOT NULL,
                sent_at REAL NOT NULL,
                subject TEXT NOT NULL,
                sender TEXT NOT NULL,
                preview TEXT NOT NULL,
                is_read INTEGER NOT NULL,
                has_attachment INTEGER NOT NULL
            );
            """)
        if existingSchema == "5" {
            try execute("""
                INSERT OR REPLACE INTO message_list
                    (entry_path, folder_id, sent_at, subject, sender, preview, is_read, has_attachment)
                SELECT entry_path, folder_id, CAST(sent_at AS REAL), subject, sender, preview,
                       CAST(is_read AS INTEGER), CAST(has_attachment AS INTEGER)
                FROM message_search;
                """)
        }
        try execute("""
            CREATE INDEX IF NOT EXISTS message_list_folder_date
            ON message_list(folder_id, sent_at DESC, entry_path ASC);
            """)
        try execute("""
            CREATE INDEX IF NOT EXISTS message_list_attachment_date
            ON message_list(has_attachment, sent_at DESC, entry_path ASC);
            """)
        try execute("""
            CREATE INDEX IF NOT EXISTS message_list_sent_date
            ON message_list(sent_at DESC, entry_path ASC);
            """)
        try setMetadataValue("6", for: "schema_version")

        let insertSQL = """
            INSERT INTO message_search
                (entry_path, folder_id, sent_at, has_attachment, is_read, subject, sender, recipients, cc_recipients, bcc_recipients, preview, body, attachments)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        guard sqlite3_prepare_v2(handle, insertSQL, -1, &insertStatement, nil) == SQLITE_OK else {
            throw SearchIndexError.operationFailed(String(cString: sqlite3_errmsg(handle)))
        }
        let listInsertSQL = """
            INSERT OR REPLACE INTO message_list
                (entry_path, folder_id, sent_at, subject, sender, preview, is_read, has_attachment)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
        guard sqlite3_prepare_v2(handle, listInsertSQL, -1, &listInsertStatement, nil) == SQLITE_OK else {
            throw SearchIndexError.operationFailed(String(cString: sqlite3_errmsg(handle)))
        }
    }

    deinit {
        if let insertStatement { sqlite3_finalize(insertStatement) }
        if let listInsertStatement { sqlite3_finalize(listInsertStatement) }
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
                message.folderID,
                String(message.sentAt.timeIntervalSince1970),
                message.attachments.isEmpty ? "0" : "1",
                message.isRead ? "1" : "0",
                message.subject,
                "\(message.sender.label) \(message.sender.address)",
                message.recipients.map { "\($0.label) \($0.address)" }.joined(separator: " "),
                message.ccRecipients.map { "\($0.label) \($0.address)" }.joined(separator: " "),
                message.bccRecipients.map { "\($0.label) \($0.address)" }.joined(separator: " "),
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
            guard let listStatement = listInsertStatement else {
                throw SearchIndexError.operationFailed("message list statement is unavailable")
            }
            sqlite3_reset(listStatement)
            sqlite3_clear_bindings(listStatement)
            let listValues = [
                entryPath,
                message.folderID,
                String(message.sentAt.timeIntervalSince1970),
                message.subject,
                "\(message.sender.label) \(message.sender.address)",
                message.preview,
                message.isRead ? "1" : "0",
                message.attachments.isEmpty ? "0" : "1"
            ]
            for (index, value) in listValues.enumerated() {
                sqlite3_bind_text(listStatement, Int32(index + 1), value, -1, Self.transient)
            }
            guard sqlite3_step(listStatement) == SQLITE_DONE else {
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

    func reset(compact: Bool) throws {
        try lock.withLock {
            try execute("BEGIN IMMEDIATE TRANSACTION;")
            do {
                try execute("DELETE FROM message_search;")
                try execute("DELETE FROM message_list;")
                try setMetadataValue("0", for: "next_entry_offset")
                try setMetadataValue("0", for: "complete")
                try execute("COMMIT;")
                if compact { try execute("VACUUM;") }
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }
    }

    var cacheByteCount: Int64 {
        lock.withLock {
            [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal"), URL(fileURLWithPath: databaseURL.path + "-shm")]
                .reduce(Int64(0)) { total, url in
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    return total + Int64(size)
                }
        }
    }

    func folderPageRecords(folderID: String, offset: Int, limit: Int) throws -> IndexedMessagePage? {
        try lock.withLock {
            guard metadataValue(for: "complete") == "1", let database else { return nil }
            let start = max(0, offset)
            let pageSize = max(1, limit)
            var statement: OpaquePointer?
            let sql = """
                SELECT entry_path, folder_id, sent_at, subject, sender, preview, is_read, has_attachment
                FROM message_list
                WHERE folder_id = ?
                ORDER BY sent_at DESC, entry_path ASC
                LIMIT ? OFFSET ?;
                """
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw SearchIndexError.operationFailed(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, folderID, -1, Self.transient)
            sqlite3_bind_int(statement, 2, Int32(pageSize))
            sqlite3_bind_int(statement, 3, Int32(start))
            var records: [IndexedMessageRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let record = Self.indexedRecord(from: statement) { records.append(record) }
            }

            var countStatement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "SELECT COUNT(*) FROM message_list WHERE folder_id = ?;",
                -1,
                &countStatement,
                nil
            ) == SQLITE_OK, let countStatement else {
                throw SearchIndexError.operationFailed(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(countStatement) }
            sqlite3_bind_text(countStatement, 1, folderID, -1, Self.transient)
            let total = sqlite3_step(countStatement) == SQLITE_ROW
                ? Int(sqlite3_column_int64(countStatement, 0))
                : records.count
            return IndexedMessagePage(
                records: records,
                nextOffset: min(start + records.count, total),
                totalCount: total
            )
        }
    }

    func folderPagePaths(folderID: String, offset: Int, limit: Int) throws -> IndexedMessagePage? {
        try folderPageRecords(folderID: folderID, offset: offset, limit: limit)
    }

    func unreadCountsByFolder() throws -> [String: Int]? {
        try lock.withLock {
            guard metadataValue(for: "complete") == "1", let database else { return nil }
            var statement: OpaquePointer?
            let sql = """
                SELECT folder_id, COUNT(*) FROM message_list
                WHERE is_read = 0
                GROUP BY folder_id;
                """
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw SearchIndexError.operationFailed(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }
            var counts: [String: Int] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let text = sqlite3_column_text(statement, 0) else { continue }
                counts[String(cString: text)] = Int(sqlite3_column_int64(statement, 1))
            }
            return counts
        }
    }

    func searchRecords(
        matching query: String,
        folderID: String?,
        offset: Int,
        limit: Int,
        sort: SearchSort
    ) throws -> IndexedMessagePage {
        try lock.withLock {
            guard let database else { return IndexedMessagePage(records: [], nextOffset: 0, totalCount: 0) }
            let parsed = SearchTerms(query)
            var predicates: [String] = []
            var bindings: [String] = []
            let expression = Self.ftsExpression(for: parsed.terms.joined(separator: " "))
            let usesFTS = !expression.isEmpty
                || parsed.sender != nil
                || parsed.recipient != nil
                || parsed.ccRecipient != nil
                || parsed.bccRecipient != nil
            let tableName = usesFTS ? "message_search" : "message_list"
            if !expression.isEmpty {
                predicates.append("message_search MATCH ?")
                bindings.append(expression)
            }
            if let sender = parsed.sender {
                predicates.append("sender LIKE ? ESCAPE '\\' COLLATE NOCASE")
                bindings.append("%\(Self.likePattern(sender))%")
            }
            if let recipient = parsed.recipient {
                predicates.append("recipients LIKE ? ESCAPE '\\' COLLATE NOCASE")
                bindings.append("%\(Self.likePattern(recipient))%")
            }
            if let ccRecipient = parsed.ccRecipient {
                predicates.append("cc_recipients LIKE ? ESCAPE '\\' COLLATE NOCASE")
                bindings.append("%\(Self.likePattern(ccRecipient))%")
            }
            if let bccRecipient = parsed.bccRecipient {
                predicates.append("bcc_recipients LIKE ? ESCAPE '\\' COLLATE NOCASE")
                bindings.append("%\(Self.likePattern(bccRecipient))%")
            }
            if let scopedFolder = folderID {
                predicates.append("folder_id = ?")
                bindings.append(scopedFolder)
            } else if let folder = parsed.folder {
                predicates.append("folder_id LIKE ? ESCAPE '\\' COLLATE NOCASE")
                bindings.append("%\(Self.likePattern(folder))%")
            }
            if let after = parsed.after {
                predicates.append(usesFTS ? "CAST(sent_at AS REAL) >= ?" : "sent_at >= ?")
                bindings.append(String(after.timeIntervalSince1970))
            }
            if let before = parsed.before {
                predicates.append(usesFTS ? "CAST(sent_at AS REAL) < ?" : "sent_at < ?")
                bindings.append(String(before.timeIntervalSince1970))
            }
            if parsed.hasAttachment {
                predicates.append(usesFTS ? "has_attachment = '1'" : "has_attachment = 1")
            }
            guard !predicates.isEmpty else { return IndexedMessagePage(records: [], nextOffset: 0, totalCount: 0) }
            let whereSQL = predicates.joined(separator: " AND ")
            let orderSQL: String
            switch sort {
            case .relevance where !expression.isEmpty: orderSQL = "rank"
            case .oldest: orderSQL = usesFTS ? "CAST(sent_at AS REAL) ASC" : "sent_at ASC"
            default: orderSQL = usesFTS ? "CAST(sent_at AS REAL) DESC" : "sent_at DESC"
            }
            let sql = "SELECT entry_path FROM \(tableName) WHERE \(whereSQL) ORDER BY \(orderSQL) LIMIT ? OFFSET ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw SearchIndexError.operationFailed(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }
            for (index, value) in bindings.enumerated() {
                sqlite3_bind_text(statement, Int32(index + 1), value, -1, Self.transient)
            }
            sqlite3_bind_int(statement, Int32(bindings.count + 1), Int32(max(1, limit)))
            sqlite3_bind_int(statement, Int32(bindings.count + 2), Int32(max(0, offset)))

            var paths: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let text = sqlite3_column_text(statement, 0) {
                    paths.append(String(cString: text))
                }
            }
            var countStatement: OpaquePointer?
            let countSQL = "SELECT COUNT(*) FROM \(tableName) WHERE \(whereSQL);"
            guard sqlite3_prepare_v2(database, countSQL, -1, &countStatement, nil) == SQLITE_OK,
                  let countStatement else {
                throw SearchIndexError.operationFailed(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(countStatement) }
            for (index, value) in bindings.enumerated() {
                sqlite3_bind_text(countStatement, Int32(index + 1), value, -1, Self.transient)
            }
            let total = sqlite3_step(countStatement) == SQLITE_ROW ? Int(sqlite3_column_int64(countStatement, 0)) : paths.count
            var records: [IndexedMessageRecord] = []
            records.reserveCapacity(paths.count)
            for path in paths {
                if let record = try Self.indexedRecord(entryPath: path, database: database) {
                    records.append(record)
                }
            }
            return IndexedMessagePage(records: records, nextOffset: min(max(0, offset) + records.count, total), totalCount: total)
        }
    }

    func searchPaths(
        matching query: String,
        folderID: String?,
        offset: Int,
        limit: Int,
        sort: SearchSort
    ) throws -> IndexedMessagePage {
        try searchRecords(
            matching: query, folderID: folderID, offset: offset, limit: limit, sort: sort
        )
    }

    private static func indexedRecord(from statement: OpaquePointer) -> IndexedMessageRecord? {
        guard let entryText = sqlite3_column_text(statement, 0),
              let folderText = sqlite3_column_text(statement, 1) else { return nil }
        func string(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
        return IndexedMessageRecord(
            entryPath: String(cString: entryText),
            folderID: String(cString: folderText),
            sentAt: Date(timeIntervalSince1970: Double(string(2)) ?? 0),
            subject: string(3),
            sender: string(4),
            preview: string(5),
            isRead: string(6) == "1",
            hasAttachment: string(7) == "1"
        )
    }

    private static func indexedRecord(
        entryPath: String, database: OpaquePointer
    ) throws -> IndexedMessageRecord? {
        var statement: OpaquePointer?
        let sql = """
            SELECT entry_path, folder_id, sent_at, subject, sender, preview, is_read, has_attachment
            FROM message_list WHERE entry_path = ?;
            """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SearchIndexError.operationFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, entryPath, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return indexedRecord(from: statement)
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

    private static func likePattern(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
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

struct IndexedMessagePage: Sendable {
    let records: [IndexedMessageRecord]
    let nextOffset: Int
    let totalCount: Int

    var paths: [String] { records.map(\.entryPath) }
}

struct IndexedMessageRecord: Sendable {
    let entryPath: String
    let folderID: String
    let sentAt: Date
    let subject: String
    let sender: String
    let preview: String
    let isRead: Bool
    let hasAttachment: Bool

    func messageSummary() -> MessageSummary {
        let attachment = AttachmentSummary(
            id: "indexed-attachment", filename: "Attachment", byteCount: 0,
            contentType: "application/octet-stream"
        )
        return MessageSummary(
            id: entryPath,
            folderID: folderID,
            subject: subject.isEmpty ? "(No Subject)" : subject,
            sender: MailParticipant(name: sender.isEmpty ? "Unknown Sender" : sender, address: ""),
            recipients: [],
            ccRecipients: [],
            bccRecipients: [],
            messageID: nil,
            sentAt: sentAt,
            receivedAt: nil,
            preview: preview,
            body: "",
            htmlBody: nil,
            isRead: isRead,
            isFlagged: false,
            attachments: hasAttachment ? [attachment] : [],
            sourceEntryPath: entryPath,
            isFullyLoaded: false
        )
    }
}

private struct SearchTerms {
    var terms: [String] = []
    var sender: String?
    var recipient: String?
    var ccRecipient: String?
    var bccRecipient: String?
    var folder: String?
    var after: Date?
    var before: Date?
    var hasAttachment = false

    init(_ query: String) {
        for token in Self.tokens(query) {
            let pair = token.split(separator: ":", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { terms.append(token); continue }
            let key = pair[0].lowercased()
            let value = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch key {
            case "from" where !value.isEmpty: sender = value
            case "to" where !value.isEmpty: recipient = value
            case "cc" where !value.isEmpty: ccRecipient = value
            case "bcc" where !value.isEmpty: bccRecipient = value
            case "folder" where !value.isEmpty: folder = value
            case "after": after = Self.date(value)
            case "before": before = Self.date(value)
            case "has" where value.lowercased() == "attachment": hasAttachment = true
            default: terms.append(token)
            }
        }
    }

    private static func tokens(_ value: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        for character in value {
            if character == "\"" || character == "'" {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
                else { current.append(character) }
            } else if character.isWhitespace && quote == nil {
                if !current.isEmpty { result.append(current); current = "" }
            } else { current.append(character) }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func date(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
