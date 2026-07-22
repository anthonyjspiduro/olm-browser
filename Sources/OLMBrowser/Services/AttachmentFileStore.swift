import Foundation

/// Owns bounded, per-session attachment materialization. The source archive is
/// only ever read; temporary files are unique and disposable.
final class AttachmentFileStore: @unchecked Sendable {
    static let maximumBatchSize: Int64 = 1_024 * 1_024 * 1_024

    private let fileManager = FileManager.default
    private let rootURL: URL
    private let sessionURL: URL
    private let lock = NSLock()

    init() {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OLMBrowser-Attachments", isDirectory: true)
        sessionURL = rootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        removeExpiredFiles(olderThan: 24 * 60 * 60)
        try? fileManager.createDirectory(at: sessionURL, withIntermediateDirectories: true)
    }

    deinit { cleanupSession() }

    func temporaryFile(for attachment: AttachmentSummary, reader: any OLMArchiveReading) throws -> URL {
        let data = try reader.attachmentData(for: attachment)
        let directory = sessionURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Self.safeFilename(attachment.filename), isDirectory: false)
        try data.write(to: url, options: [.atomic])
        return url
    }

    func export(_ attachment: AttachmentSummary, to destination: URL, reader: any OLMArchiveReading) throws {
        let data = try reader.attachmentData(for: attachment)
        try data.write(to: destination, options: [.atomic])
    }

    func exportAll(_ attachments: [AttachmentSummary], to directory: URL, reader: any OLMArchiveReading) throws -> Int {
        let available = attachments.filter(\.isAvailable)
        let total = available.reduce(Int64(0)) { partial, item in
            let (sum, overflow) = partial.addingReportingOverflow(item.byteCount)
            return overflow ? Int64.max : sum
        }
        guard total <= Self.maximumBatchSize else {
            throw AttachmentAccessError.unavailable("The combined attachments exceed the \(ByteCountFormatter.string(fromByteCount: Self.maximumBatchSize, countStyle: .file)) export limit.")
        }
        var exported = 0
        for attachment in available {
            let destination = uniqueDestination(in: directory, filename: attachment.filename)
            try export(attachment, to: destination, reader: reader)
            exported += 1
        }
        return exported
    }

    func cleanupSession() {
        lock.withLock { try? fileManager.removeItem(at: sessionURL) }
    }

    private func removeExpiredFiles(olderThan age: TimeInterval) {
        guard let children = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for child in children {
            let modified = try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if modified.map({ $0 < cutoff }) ?? true { try? fileManager.removeItem(at: child) }
        }
    }

    private func uniqueDestination(in directory: URL, filename: String) -> URL {
        let safe = Self.safeFilename(filename)
        let stem = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension
        var candidate = directory.appendingPathComponent(safe)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let suffix = ext.isEmpty ? " \(counter)" : " \(counter).\(ext)"
            candidate = directory.appendingPathComponent(stem + suffix)
            counter += 1
        }
        return candidate
    }

    static func safeFilename(_ filename: String) -> String {
        let leaf = (filename as NSString).lastPathComponent
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return leaf.isEmpty || leaf == "." || leaf == ".." ? "Attachment" : String(leaf.prefix(240))
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
