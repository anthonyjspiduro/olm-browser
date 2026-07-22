import Foundation

@main
enum ArchiveSmokeCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw CheckFailure("Usage: archive-check /path/to/archive.olm")
        }

        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let snapshot = try NativeOLMArchiveReader().openArchive(at: url)
        guard let folder = snapshot.folders.first(where: { $0.messageCount > 150 }) else {
            throw CheckFailure("No folder large enough to test paging")
        }
        let firstPage = try NativeOLMArchiveReaderCheck.shared.loadFirstPage(
            readerURL: url,
            folderID: folder.id
        )
        print("Archive: \(snapshot.identity.displayName)")
        print("Accounts: \(snapshot.accounts.count)")
        print("Folders: \(snapshot.folders.count)")
        print("Cataloged messages: \(snapshot.folders.reduce(0) { $0 + $1.messageCount })")
        print("Paging check: \(firstPage) unique messages across two pages")
    }
}

private final class NativeOLMArchiveReaderCheck {
    static let shared = NativeOLMArchiveReaderCheck()

    func loadFirstPage(readerURL: URL, folderID: MailFolder.ID) throws -> Int {
        let reader = NativeOLMArchiveReader()
        _ = try reader.openArchive(at: readerURL)
        let first = try reader.loadMessages(in: folderID, offset: 0, limit: 100)
        let second = try reader.loadMessages(in: folderID, offset: first.nextOffset, limit: 100)
        let ids = Set((first.messages + second.messages).map(\.id))
        guard first.nextOffset == 100, second.nextOffset == 200, ids.count == 200 else {
            throw CheckFailure("Paging returned duplicate or incorrect offsets")
        }
        return ids.count
    }
}

private struct CheckFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
