import Foundation

@main
enum PagingPerformanceCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw Failure("Usage: paging-performance-check /path/to/archive.olm")
        }
        let reader = NativeOLMArchiveReader()
        let archiveURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let openStart = ContinuousClock.now
        let snapshot = try reader.openArchive(at: archiveURL)
        let openDuration = openStart.duration(to: .now)
        guard let folder = snapshot.folders.max(by: { $0.messageCount < $1.messageCount }) else {
            throw Failure("No folder available")
        }

        let firstStart = ContinuousClock.now
        let first = try reader.loadMessages(in: folder.id, offset: 0, limit: 100)
        let firstDuration = firstStart.duration(to: .now)
        let secondStart = ContinuousClock.now
        let second = try reader.loadMessages(in: folder.id, offset: first.nextOffset, limit: 100)
        let secondDuration = secondStart.duration(to: .now)
        let distantOffset = min(10_000, max(0, folder.messageCount - 200))
        let distantStart = ContinuousClock.now
        let distant = try reader.loadMessages(in: folder.id, offset: distantOffset, limit: 100)
        let distantDuration = distantStart.duration(to: .now)

        guard first.messages.count == 100, second.messages.count == 100 else {
            throw Failure("Expected two full 100-message pages")
        }
        print("Catalog duration: \(openDuration)")
        print("First 100-message page: \(firstDuration)")
        print("Second 100-message page: \(secondDuration)")
        print("Distant 100-message page: \(distantDuration)")
        print("Paging performance sample passed with \(first.messages.count + second.messages.count + distant.messages.count) messages")
    }
}

private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
