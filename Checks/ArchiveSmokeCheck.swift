import Foundation

@main
enum ArchiveSmokeCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw CheckFailure("Usage: archive-check /path/to/archive.olm")
        }

        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let snapshot = try NativeOLMArchiveReader().openArchive(at: url)
        print("Archive: \(snapshot.identity.displayName)")
        print("Accounts: \(snapshot.accounts.count)")
        print("Folders: \(snapshot.folders.count)")
        print("Loaded message sample: \(snapshot.messages.count)")
        print("Cataloged messages: \(snapshot.folders.reduce(0) { $0 + $1.messageCount })")
    }
}

private struct CheckFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
