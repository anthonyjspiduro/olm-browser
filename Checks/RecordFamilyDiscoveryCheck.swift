import Foundation

@main
enum RecordFamilyDiscoveryCheck {
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else {
            print("Usage: RecordFamilyDiscoveryCheck <archive.olm> [--schema Basename.xml]")
            return
        }
        let archive = try ZIPArchive(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        if CommandLine.arguments.count == 4, CommandLine.arguments[2] == "--schema" {
            try printSchema(
                basename: CommandLine.arguments[3],
                entries: archive.entries,
                archive: archive
            )
            return
        }
        var xmlBasenames: [String: Int] = [:]
        for entry in archive.entries where entry.path.hasSuffix(".xml") {
            let basename = entry.path.split(separator: "/").last.map(String.init) ?? entry.path
            let safeName = basename.hasPrefix("message_") ? "message_*.xml" : basename
            xmlBasenames[safeName, default: 0] += 1
        }
        print("Archive entries: \(archive.entries.count)")
        print("XML entry families: \(xmlBasenames.count)")
        for (name, count) in xmlBasenames.sorted(by: { $0.key < $1.key }) {
            print("\(name): \(count)")
        }
    }

    private static func printSchema(
        basename: String,
        entries: [ZIPEntry],
        archive: ZIPArchive
    ) throws {
        let matches = entries.filter {
            $0.path.split(separator: "/").last.map(String.init) == basename
        }
        var elementCounts: [String: Int] = [:]
        var attributeCounts: [String: Int] = [:]
        var recurrenceValues: [String: [String: Int]] = [:]
        var contactImageStats: [String: Int] = [:]
        for entry in matches {
            let data = try archive.data(for: entry, maximumSize: 512 * 1_024 * 1_024)
            let inspector = XMLSchemaInspector()
            inspector.parse(data)
            for (name, count) in inspector.elementCounts {
                elementCounts[name, default: 0] += count
            }
            for (name, count) in inspector.attributeCounts {
                attributeCounts[name, default: 0] += count
            }
            for (field, values) in inspector.recurrenceValues {
                for (value, count) in values {
                    recurrenceValues[field, default: [:]][value, default: 0] += count
                }
            }
            for (classification, count) in inspector.contactImageStats {
                contactImageStats[classification, default: 0] += count
            }
        }
        print("Matching collections: \(matches.count)")
        print("Element names:")
        for (name, count) in elementCounts.sorted(by: { $0.key < $1.key }) {
            print("\(name): \(count)")
        }
        print("Attribute names:")
        for (name, count) in attributeCounts.sorted(by: { $0.key < $1.key }) {
            print("\(name): \(count)")
        }
        if !recurrenceValues.isEmpty {
            print("Technical recurrence values:")
            for (field, values) in recurrenceValues.sorted(by: { $0.key < $1.key }) {
                for (value, count) in values.sorted(by: { $0.key < $1.key }) {
                    print("\(field)=\(value): \(count)")
                }
            }
        }
        if !contactImageStats.isEmpty {
            print("Contact image encodings:")
            for (classification, count) in contactImageStats.sorted(by: { $0.key < $1.key }) {
                print("\(classification): \(count)")
            }
        }
    }
}

private final class XMLSchemaInspector: NSObject, XMLParserDelegate {
    var elementCounts: [String: Int] = [:]
    var attributeCounts: [String: Int] = [:]
    var recurrenceValues: [String: [String: Int]] = [:]
    var contactImageStats: [String: Int] = [:]
    private var currentElement = ""
    private var text = ""

    func parse(_ data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        text = ""
        elementCounts[elementName, default: 0] += 1
        for name in attributeDict.keys {
            attributeCounts[name, default: 0] += 1
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if elementName.localizedCaseInsensitiveContains("recurrencepattern")
            || elementName == "OPFRecurrenceGetOccurenceCount",
           isSafeTechnicalValue(value) {
            recurrenceValues[elementName, default: [:]][value, default: 0] += 1
        }
        if elementName == "OPFContactCopyContactImage" {
            let classification: String
            if value.isEmpty {
                classification = "empty"
            } else if let number = Double(value) {
                classification = number == 0 ? "numeric-zero" : "numeric-nonzero"
            } else if value.hasPrefix("data:image/") {
                classification = "data-image-uri"
            } else if value.contains("/") || value.contains("\\") {
                classification = "path-or-reference"
            } else if UUID(uuidString: value) != nil {
                classification = "uuid-reference"
            } else if Data(base64Encoded: value, options: .ignoreUnknownCharacters) != nil {
                classification = "base64"
            } else {
                classification = "other-nonempty"
            }
            let lengthBucket: String
            switch value.utf8.count {
            case 0: lengthBucket = "0-bytes"
            case 1...1_024: lengthBucket = "1-1024-bytes"
            case 1_025...1_048_576: lengthBucket = "1KB-1MB"
            default: lengthBucket = "over-1MB"
            }
            contactImageStats["\(classification), \(lengthBucket)", default: 0] += 1
        }
        currentElement = ""
        text = ""
    }

    private func isSafeTechnicalValue(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 80 else { return false }
        return value.allSatisfy {
            $0.isNumber || $0.isLetter || $0 == "-" || $0 == "_" || $0 == ":" || $0 == "."
        }
    }
}
