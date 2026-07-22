import Foundation

enum MessageBatchExportError: LocalizedError {
    case tooManyMessages(limit: Int)
    case tooLarge(limit: Int64)

    var errorDescription: String? {
        switch self {
        case .tooManyMessages(let limit):
            "A batch can contain at most \(limit.formatted()) loaded messages."
        case .tooLarge(let limit):
            "The batch exceeds the \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)) export limit."
        }
    }
}

enum MessageBatchExporter {
    static let maximumMessageCount = 1_000
    static let maximumOutputBytes: Int64 = 1_024 * 1_024 * 1_024

    static func csvData(for messages: [MessageSummary]) throws -> Data {
        guard messages.count <= maximumMessageCount else {
            throw MessageBatchExportError.tooManyMessages(limit: maximumMessageCount)
        }
        let data = MessageExporter.csvData(for: messages)
        guard Int64(data.count) <= maximumOutputBytes else {
            throw MessageBatchExportError.tooLarge(limit: maximumOutputBytes)
        }
        return data
    }

    static func exportFiles(
        _ messages: [MessageSummary],
        format: MessageExportFormat,
        to directory: URL,
        reader: any OLMArchiveReading
    ) throws -> Int {
        guard messages.count <= maximumMessageCount else {
            throw MessageBatchExportError.tooManyMessages(limit: maximumMessageCount)
        }
        guard format != .csv else {
            throw AttachmentAccessError.invalidDestination
        }

        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("OLMBrowser-MessageExport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        var staged: [(URL, String)] = []
        var totalBytes: Int64 = 0
        for (index, message) in messages.enumerated() {
            let data = try MessageExporter.data(for: message, format: format, reader: reader)
            let (newTotal, overflow) = totalBytes.addingReportingOverflow(Int64(data.count))
            guard !overflow, newTotal <= maximumOutputBytes else {
                throw MessageBatchExportError.tooLarge(limit: maximumOutputBytes)
            }
            totalBytes = newTotal
            let sequence = String(format: "%04d", index + 1)
            let subject = AttachmentFileStore.safeFilename(message.subject)
            let filename = "\(sequence) \(subject).\(format.rawValue)"
            let stagedURL = staging.appendingPathComponent(filename)
            try data.write(to: stagedURL, options: [.atomic])
            staged.append((stagedURL, filename))
        }

        for (source, filename) in staged {
            let destination = uniqueDestination(in: directory, filename: filename, fileManager: fileManager)
            try fileManager.copyItem(at: source, to: destination)
        }
        return staged.count
    }

    private static func uniqueDestination(
        in directory: URL,
        filename: String,
        fileManager: FileManager
    ) -> URL {
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}
