import Foundation

@main
enum ArchiveAccessSmokeCheck {
    static func main() throws {
        let suiteName = "OLMBrowser.ArchiveAccessSmoke.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw Failure("Could not create isolated preferences")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("Synthetic Archive \(UUID().uuidString).olm")
        guard FileManager.default.createFile(atPath: file.path, contents: Data("synthetic".utf8)) else {
            throw Failure("Could not create synthetic file")
        }
        defer { try? FileManager.default.removeItem(at: file) }

        let manager = ArchiveAccessManager(defaults: defaults)
        manager.remember(file)
        let recent = manager.recentArchives
        guard recent.count == 1, recent[0].displayName == file.lastPathComponent else {
            throw Failure("Recent archive was not stored")
        }
        guard manager.resolveRecent(id: recent[0].id)?.standardizedFileURL == file.standardizedFileURL else {
            throw Failure("Security-scoped bookmark did not resolve")
        }
        manager.forget(id: recent[0].id)
        guard manager.recentArchives.isEmpty else {
            throw Failure("Recent archive was not removed")
        }
        print("Recent archive security-bookmark checks passed")
    }
}

private struct Failure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
