import Foundation

@main
enum ArchiveIntegritySmokeCheck {
    static func main() throws {
        let good = Data("123456789".utf8)
        let damaged = Data("damaged entry".utf8)
        let unsupported = Data("unsupported entry".utf8)
        let archiveData = makeArchive(entries: [
            Entry(path: "good.txt", method: 0, data: good, declaredCRC: 0xcbf4_3926),
            Entry(path: "damaged.txt", method: 0, data: damaged, declaredCRC: 0),
            Entry(path: "unsupported.txt", method: 99, data: unsupported, declaredCRC: 0)
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("olm-integrity-\(UUID().uuidString).zip")
        try archiveData.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try ZIPArchive(url: url)
        try require(try archive.data(for: archive.entries[0]) == good, "valid CRC entry reads")

        do {
            _ = try archive.data(for: archive.entries[1])
            throw Failure("CRC mismatch was not rejected")
        } catch ZIPArchiveError.checksumMismatch(let expected, let actual) {
            try require(expected != actual, "CRC diagnostic includes differing values")
        }

        do {
            _ = try archive.data(for: archive.entries[2])
            throw Failure("unsupported compression was not rejected")
        } catch ZIPArchiveError.unsupportedCompression(let method) {
            try require(method == 99, "unsupported method is reported")
        }

        try require(try archive.data(for: archive.entries[0]) == good, "one corrupt entry does not poison healthy entries")
        print("ZIP CRC, unsupported-compression, and entry-isolation smoke checks passed")
    }

    private struct Entry {
        let path: String
        let method: UInt16
        let data: Data
        let declaredCRC: UInt32
    }

    private static func makeArchive(entries: [Entry]) -> Data {
        var result = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.path.utf8)
            let offset = UInt32(result.count)
            result.appendLE(UInt32(0x04034b50)); result.appendLE(UInt16(20)); result.appendLE(UInt16(0))
            result.appendLE(entry.method); result.appendLE(UInt16(0)); result.appendLE(UInt16(0))
            result.appendLE(entry.declaredCRC); result.appendLE(UInt32(entry.data.count)); result.appendLE(UInt32(entry.data.count))
            result.appendLE(UInt16(name.count)); result.appendLE(UInt16(0)); result.append(name); result.append(entry.data)

            central.appendLE(UInt32(0x02014b50)); central.appendLE(UInt16(20)); central.appendLE(UInt16(20))
            central.appendLE(UInt16(0)); central.appendLE(entry.method); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(entry.declaredCRC); central.appendLE(UInt32(entry.data.count)); central.appendLE(UInt32(entry.data.count))
            central.appendLE(UInt16(name.count)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt32(0)); central.appendLE(offset); central.append(name)
        }
        let centralOffset = UInt32(result.count)
        result.append(central)
        result.appendLE(UInt32(0x06054b50)); result.appendLE(UInt16(0)); result.appendLE(UInt16(0))
        result.appendLE(UInt16(entries.count)); result.appendLE(UInt16(entries.count))
        result.appendLE(UInt32(central.count)); result.appendLE(centralOffset); result.appendLE(UInt16(0))
        return result
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw Failure("Failed: \(label)") }
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xff)); append(UInt8(value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xff)); append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff)); append(UInt8(value >> 24))
    }
}

private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
