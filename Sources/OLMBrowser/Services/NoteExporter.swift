import Foundation

enum NoteExportFormat: String, CaseIterable, Identifiable, Sendable {
    case text = "txt"
    case json
    case csv

    var id: String { rawValue }
    var label: String {
        switch self {
        case .text: "Text"
        case .json: "JSON"
        case .csv: "CSV"
        }
    }
}

enum NoteExporter {
    static func data(_ notes: [NoteRecord], format: NoteExportFormat) throws -> Data {
        switch format {
        case .text:
            return Data(text(notes).utf8)
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(notes.map(ExportNote.init))
        case .csv:
            return Data(csv(notes).utf8)
        }
    }

    private static func text(_ notes: [NoteRecord]) -> String {
        notes.map { note in
            var lines = [note.title]
            if let created = note.createdAt {
                lines.append("Created: \(created.formatted(date: .long, time: .shortened))")
            }
            if let modified = note.modifiedAt {
                lines.append("Modified: \(modified.formatted(date: .long, time: .shortened))")
            }
            lines.append("")
            lines.append(note.text)
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n---\n\n")
    }

    private static func csv(_ notes: [NoteRecord]) -> String {
        let rows = [["Title", "Created", "Modified", "Text"]] + notes.map { note in
            [
                note.title,
                note.createdAt.map(ISO8601DateFormatter().string) ?? "",
                note.modifiedAt.map(ISO8601DateFormatter().string) ?? "",
                note.text
            ]
        }
        return rows.map {
            $0.map(csvField).joined(separator: ",")
        }.joined(separator: "\r\n") + "\r\n"
    }

    private static func csvField(_ value: String) -> String {
        let dangerous = ["=", "+", "-", "@"].contains {
            value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix($0)
        }
        let safe = dangerous ? "'\(value)" : value
        return "\"\(safe.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private struct ExportNote: Codable {
        let title: String
        let text: String
        let createdAt: Date?
        let modifiedAt: Date?

        init(_ note: NoteRecord) {
            title = note.title
            text = note.text
            createdAt = note.createdAt
            modifiedAt = note.modifiedAt
        }
    }
}
