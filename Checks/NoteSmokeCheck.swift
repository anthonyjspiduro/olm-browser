import Foundation

@main
enum NoteSmokeCheck {
    static func main() throws {
        let source = ArchiveItemSource(
            id: "synthetic-notes",
            accountID: "synthetic@example.invalid",
            name: "Notes",
            kind: .notes,
            entryPath: "synthetic/private-path/Notes.xml"
        )
        let xml = """
        <notes elementCount="2">
          <note>
            <OPFNoteCopyText>Recovery checklist
        Verify contacts and calendar.</OPFNoteCopyText>
            <OPFNoteCopyCreationDate>2026-07-20T12:00:00Z</OPFNoteCopyCreationDate>
            <OPFNoteCopyModDate>2026-07-21T13:30:00Z</OPFNoteCopyModDate>
          </note>
          <note>
            <OPFNoteCopyText>=Synthetic formula-prefixed note</OPFNoteCopyText>
            <OPFNoteCopyCreationDate>2026-07-22T09:00:00Z</OPFNoteCopyCreationDate>
          </note>
        </notes>
        """
        let progress = NoteProgressRecorder()
        let notes = OLMNoteParser().parse(
            data: Data(xml.utf8),
            source: source,
            progress: { progress.record($0) }
        )
        require(notes.count == 2, "note count")
        require(notes[0].title == "Recovery checklist", "first-line note title")
        require(notes[0].createdAt != nil && notes[0].modifiedAt != nil, "note dates")
        require(progress.lastValue == 2, "note parse progress")

        let text = String(
            decoding: try NoteExporter.data(notes, format: .text),
            as: UTF8.self
        )
        require(text.contains("Recovery checklist"), "text note export")

        let json = String(
            decoding: try NoteExporter.data(notes, format: .json),
            as: UTF8.self
        )
        require(
            json.contains("\"text\"") && !json.contains("private-path")
                && !json.contains("\"sourceID\""),
            "JSON exports content without internal archive paths"
        )

        let csv = String(
            decoding: try NoteExporter.data(notes, format: .csv),
            as: UTF8.self
        )
        require(
            csv.contains("\"'=Synthetic formula-prefixed note\""),
            "CSV formula neutralization"
        )
        print("Note parser, privacy, and text/JSON/CSV export checks passed")
        print("Notes checked: \(notes.count)")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError("Failed: \(label)") }
    }
}

private final class NoteProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var lastValue: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func record(_ newValue: Int) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
