import Foundation

@main
enum ArchiveSearchSmokeCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw Failure("Usage: archive-search-check /path/to/archive.olm") }
        let reader = NativeOLMArchiveReader()
        _ = try reader.openArchive(at: URL(fileURLWithPath: CommandLine.arguments[1]))
        let progress = ProgressBox()
        try reader.buildSearchIndex { progress.value = $0 }
        let finalProgress = progress.value
        guard finalProgress.isComplete else { throw Failure("Index did not complete") }

        let first = try reader.searchMessages(
            matching: "has:attachment", folderID: nil, offset: 0, limit: 100, sort: .newest
        )
        guard first.totalCount >= first.messages.count else { throw Failure("Invalid search total") }
        if first.totalCount > 100 {
            let second = try reader.searchMessages(
                matching: "has:attachment", folderID: nil, offset: first.nextOffset, limit: 100, sort: .newest
            )
            let unique = Set((first.messages + second.messages).map(\.id))
            guard unique.count == first.messages.count + second.messages.count else { throw Failure("Search paging returned duplicates") }
        }
        if let folderID = first.messages.first?.folderID {
            let scoped = try reader.searchMessages(
                matching: "has:attachment", folderID: folderID, offset: 0, limit: 100, sort: .oldest
            )
            guard scoped.messages.allSatisfy({ $0.folderID == folderID }) else { throw Failure("Folder scope escaped its folder") }
        }
        let syntheticSender = try reader.searchMessages(
            matching: "from:no-such-synthetic-address@example.invalid", folderID: nil, offset: 0, limit: 10, sort: .relevance
        )
        let syntheticDate = try reader.searchMessages(
            matching: "after:2999-01-01", folderID: nil, offset: 0, limit: 10, sort: .newest
        )
        guard syntheticSender.totalCount == 0, syntheticDate.totalCount == 0 else {
            throw Failure("Synthetic negative filters unexpectedly matched")
        }
        print("Indexed messages: \(finalProgress.indexed)")
        print("Unreadable messages: \(finalProgress.failed)")
        print("Messages with attachments: \(first.totalCount)")
        print("Structured filter, folder scope, sorting, and search paging checks passed")
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = IndexProgress(indexed: 0, total: 0, isComplete: false)
    var value: IndexProgress {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
