import Foundation

@main
enum IndexPerformanceCheck {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw Failure("Usage: index-performance-check /path/to/archive.olm")
        }
        let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let aliasURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("olm-index-performance-\(UUID().uuidString).olm")
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: sourceURL)
        defer { try? FileManager.default.removeItem(at: aliasURL) }

        let reader = NativeOLMArchiveReader()
        let snapshot = try reader.openArchive(at: aliasURL)
        let total = snapshot.folders.reduce(0) { $0 + $1.messageCount }
        let clock = ContinuousClock()
        let start = clock.now
        let target = min(1_000, total)
        let progressBox = ProgressBox()
        let task = Task.detached(priority: .userInitiated) {
            try reader.buildSearchIndex { progress in
                progressBox.value = progress.indexed
                if progress.indexed >= target {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        _ = try await task.value
        let duration = start.duration(to: clock.now)
        let indexed = progressBox.value
        try reader.deleteSearchCache()

        print("Parallel index sample: \(indexed) of \(total) messages")
        print("Parallel index duration: \(duration)")
        print("Temporary derived search content deleted")
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
