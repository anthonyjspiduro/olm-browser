import CZipSupport
import Foundation

enum ZIPArchiveError: LocalizedError {
    case invalidArchive(String)
    case unsupportedCompression(UInt16)
    case encryptedEntry
    case entryTooLarge(UInt64)
    case truncatedEntry
    case decompressionFailed(Int32)
    case checksumMismatch(expected: UInt32, actual: UInt32)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidArchive(let reason): "Invalid ZIP archive: \(reason)"
        case .unsupportedCompression(let method): "Unsupported ZIP compression method \(method)."
        case .encryptedEntry: "Encrypted ZIP entries are not supported."
        case .entryTooLarge(let size): "The requested entry is too large to preview (\(size) bytes)."
        case .truncatedEntry: "The ZIP entry ended unexpectedly."
        case .decompressionFailed(let code): "The ZIP entry could not be decompressed (zlib \(code))."
        case .checksumMismatch(let expected, let actual):
            "The ZIP entry failed its CRC-32 integrity check (expected \(String(format: "%08X", expected)), got \(String(format: "%08X", actual)))."
        case .cancelled: "Opening the archive was cancelled."
        }
    }
}

struct ZIPEntry: Sendable, Hashable {
    let path: String
    let flags: UInt16
    let compressionMethod: UInt16
    let crc32: UInt32
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let localHeaderOffset: UInt64

    var isDirectory: Bool { path.hasSuffix("/") }
}

/// A read-only ZIP64 reader optimized for cataloging very large Outlook OLM files.
/// It reads the central directory once and opens a fresh file handle for each
/// random-access entry read, so the archive is never rewritten or expanded.
final class ZIPArchive: @unchecked Sendable {
    let url: URL
    let entries: [ZIPEntry]

    init(url: URL) throws {
        self.url = url
        self.entries = try Self.readCentralDirectory(at: url)
    }

    func data(for entry: ZIPEntry, maximumSize: UInt64 = 64 * 1_024 * 1_024) throws -> Data {
        guard entry.uncompressedSize <= maximumSize else {
            throw ZIPArchiveError.entryTooLarge(entry.uncompressedSize)
        }
        guard entry.flags & 0x0001 == 0 else {
            throw ZIPArchiveError.encryptedEntry
        }
        guard entry.compressedSize <= UInt64(Int.max),
              entry.uncompressedSize <= UInt64(Int.max) else {
            throw ZIPArchiveError.entryTooLarge(entry.uncompressedSize)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        try handle.seek(toOffset: entry.localHeaderOffset)
        let header = try handle.read(upToCount: 30) ?? Data()
        guard header.count == 30, header.uint32LE(at: 0) == 0x04034b50 else {
            throw ZIPArchiveError.invalidArchive("missing local file header")
        }

        let nameLength = UInt64(header.uint16LE(at: 26))
        let extraLength = UInt64(header.uint16LE(at: 28))
        let dataOffset = entry.localHeaderOffset + 30 + nameLength + extraLength
        try handle.seek(toOffset: dataOffset)
        let compressed = try handle.read(upToCount: Int(entry.compressedSize)) ?? Data()
        guard compressed.count == Int(entry.compressedSize) else {
            throw ZIPArchiveError.truncatedEntry
        }

        let result: Data
        switch entry.compressionMethod {
        case 0:
            guard compressed.count == Int(entry.uncompressedSize) else {
                throw ZIPArchiveError.truncatedEntry
            }
            result = compressed
        case 8:
            result = try inflate(compressed, outputSize: Int(entry.uncompressedSize))
        default:
            throw ZIPArchiveError.unsupportedCompression(entry.compressionMethod)
        }
        let actualCRC = result.withUnsafeBytes { buffer in
            olm_crc32(buffer.bindMemory(to: UInt8.self).baseAddress, result.count)
        }
        guard actualCRC == entry.crc32 else {
            throw ZIPArchiveError.checksumMismatch(expected: entry.crc32, actual: actualCRC)
        }
        return result
    }

    private func inflate(_ compressed: Data, outputSize: Int) throws -> Data {
        if outputSize == 0 { return Data() }
        var output = Data(count: outputSize)
        var written = 0
        let result: Int32 = compressed.withUnsafeBytes { inputBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                olm_inflate_raw(
                    inputBuffer.bindMemory(to: UInt8.self).baseAddress,
                    compressed.count,
                    outputBuffer.bindMemory(to: UInt8.self).baseAddress,
                    outputSize,
                    &written
                )
            }
        }
        guard result == 0 else { throw ZIPArchiveError.decompressionFailed(result) }
        guard written == outputSize else { throw ZIPArchiveError.truncatedEntry }
        return output
    }

    private static func readCentralDirectory(at url: URL) throws -> [ZIPEntry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        let tailSize = min(fileSize, 65_557)
        try handle.seek(toOffset: fileSize - tailSize)
        let tail = try handle.readToEnd() ?? Data()
        guard let relativeEOCD = tail.lastOffset(of: 0x06054b50) else {
            throw ZIPArchiveError.invalidArchive("end-of-central-directory record not found")
        }

        let absoluteEOCD = fileSize - tailSize + UInt64(relativeEOCD)
        guard relativeEOCD + 22 <= tail.count else {
            throw ZIPArchiveError.invalidArchive("truncated end-of-central-directory record")
        }

        var entryCount = UInt64(tail.uint16LE(at: relativeEOCD + 10))
        var directorySize = UInt64(tail.uint32LE(at: relativeEOCD + 12))
        var directoryOffset = UInt64(tail.uint32LE(at: relativeEOCD + 16))

        if entryCount == 0xffff || directorySize == 0xffff_ffff || directoryOffset == 0xffff_ffff {
            guard absoluteEOCD >= 20 else {
                throw ZIPArchiveError.invalidArchive("ZIP64 locator missing")
            }
            try handle.seek(toOffset: absoluteEOCD - 20)
            let locator = try handle.read(upToCount: 20) ?? Data()
            guard locator.count == 20, locator.uint32LE(at: 0) == 0x07064b50 else {
                throw ZIPArchiveError.invalidArchive("ZIP64 locator missing")
            }
            let zip64Offset = locator.uint64LE(at: 8)
            try handle.seek(toOffset: zip64Offset)
            let record = try handle.read(upToCount: 56) ?? Data()
            guard record.count >= 56, record.uint32LE(at: 0) == 0x06064b50 else {
                throw ZIPArchiveError.invalidArchive("ZIP64 end record missing")
            }
            entryCount = record.uint64LE(at: 32)
            directorySize = record.uint64LE(at: 40)
            directoryOffset = record.uint64LE(at: 48)
        }

        guard directorySize <= UInt64(Int.max), directoryOffset + directorySize <= fileSize else {
            throw ZIPArchiveError.invalidArchive("central directory lies outside the file")
        }

        try handle.seek(toOffset: directoryOffset)
        let directory = try handle.read(upToCount: Int(directorySize)) ?? Data()
        guard directory.count == Int(directorySize) else {
            throw ZIPArchiveError.invalidArchive("truncated central directory")
        }

        var result: [ZIPEntry] = []
        result.reserveCapacity(Int(min(entryCount, UInt64(Int.max))))
        var cursor = 0
        while cursor + 46 <= directory.count && UInt64(result.count) < entryCount {
            if result.count.isMultiple(of: 1_000), Task.isCancelled { throw ZIPArchiveError.cancelled }
            guard directory.uint32LE(at: cursor) == 0x02014b50 else {
                throw ZIPArchiveError.invalidArchive("invalid central-directory entry at offset \(cursor)")
            }

            let flags = directory.uint16LE(at: cursor + 8)
            let method = directory.uint16LE(at: cursor + 10)
            let crc = directory.uint32LE(at: cursor + 16)
            var compressedSize = UInt64(directory.uint32LE(at: cursor + 20))
            var uncompressedSize = UInt64(directory.uint32LE(at: cursor + 24))
            let nameLength = Int(directory.uint16LE(at: cursor + 28))
            let extraLength = Int(directory.uint16LE(at: cursor + 30))
            let commentLength = Int(directory.uint16LE(at: cursor + 32))
            var localOffset = UInt64(directory.uint32LE(at: cursor + 42))
            let recordLength = 46 + nameLength + extraLength + commentLength
            guard cursor + recordLength <= directory.count else {
                throw ZIPArchiveError.invalidArchive("truncated central-directory entry")
            }

            let nameData = directory.subdata(in: cursor + 46 ..< cursor + 46 + nameLength)
            let path = String(data: nameData, encoding: .utf8)
                ?? String(decoding: nameData, as: UTF8.self)
            let extraStart = cursor + 46 + nameLength
            let extraEnd = extraStart + extraLength

            if compressedSize == 0xffff_ffff || uncompressedSize == 0xffff_ffff || localOffset == 0xffff_ffff {
                var extraCursor = extraStart
                while extraCursor + 4 <= extraEnd {
                    let fieldID = directory.uint16LE(at: extraCursor)
                    let fieldSize = Int(directory.uint16LE(at: extraCursor + 2))
                    let valueStart = extraCursor + 4
                    let valueEnd = valueStart + fieldSize
                    guard valueEnd <= extraEnd else { break }
                    if fieldID == 0x0001 {
                        var valueCursor = valueStart
                        if uncompressedSize == 0xffff_ffff, valueCursor + 8 <= valueEnd {
                            uncompressedSize = directory.uint64LE(at: valueCursor)
                            valueCursor += 8
                        }
                        if compressedSize == 0xffff_ffff, valueCursor + 8 <= valueEnd {
                            compressedSize = directory.uint64LE(at: valueCursor)
                            valueCursor += 8
                        }
                        if localOffset == 0xffff_ffff, valueCursor + 8 <= valueEnd {
                            localOffset = directory.uint64LE(at: valueCursor)
                        }
                        break
                    }
                    extraCursor = valueEnd
                }
            }

            result.append(ZIPEntry(
                path: path,
                flags: flags,
                compressionMethod: method,
                crc32: crc,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localOffset
            ))
            cursor += recordLength
        }

        guard UInt64(result.count) == entryCount else {
            throw ZIPArchiveError.invalidArchive("expected \(entryCount) entries, found \(result.count)")
        }
        return result
    }
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func uint64LE(at offset: Int) -> UInt64 {
        UInt64(uint32LE(at: offset)) | (UInt64(uint32LE(at: offset + 4)) << 32)
    }

    func lastOffset(of signature: UInt32) -> Int? {
        guard count >= 4 else { return nil }
        for offset in stride(from: count - 4, through: 0, by: -1) {
            if uint32LE(at: offset) == signature { return offset }
        }
        return nil
    }
}
