//
//  ZipArchive.swift
//  SwiftAgentKitTools
//
//  A minimal ZIP reader, for Office files.
//

import Foundation
import Compression

/// Reads entries out of a ZIP archive.
///
/// `.docx`, `.pptx` and `.xlsx` are ZIP archives of XML, so reading them needs a
/// ZIP reader — and there wasn't one in the graph. Rather than take a
/// dependency for it, this parses the central directory and inflates with
/// Apple's Compression framework: in-process, sandbox-safe, no subprocess, and
/// no third-party code in the path of a file a stranger emailed you.
///
/// Deliberately partial. It reads what the Office formats actually use —
/// stored and deflated entries — and refuses anything else rather than
/// guessing. Encrypted and ZIP64 archives are reported as unsupported.
enum ZipArchive {

    enum Failure: Error, CustomStringConvertible {
        case notAZip
        case unsupported(String)

        var description: String {
            switch self {
            case .notAZip: "not a ZIP archive (Office files are ZIP containers)"
            case .unsupported(let why): "unsupported ZIP feature: \(why)"
            }
        }
    }

    struct Entry {
        let name: String
        /// Offset of the LOCAL header, which is where the data actually lives.
        let localHeaderOffset: Int
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
    }

    /// Every entry in the archive, by name.
    ///
    /// Mapped rather than read: an Office file can be tens of megabytes and only
    /// a few parts of it are ever wanted.
    static func entries(of url: URL) throws -> [String: Entry] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let eocd = endOfCentralDirectory(in: data) else { throw Failure.notAZip }

        let count = Int(read16(data, eocd + 10))
        var offset = Int(read32(data, eocd + 16))
        guard offset > 0, offset < data.count else {
            throw Failure.unsupported("ZIP64 or a damaged central directory")
        }

        var found: [String: Entry] = [:]
        for _ in 0..<count {
            guard offset + 46 <= data.count, read32(data, offset) == 0x02014b50 else { break }
            let method = read16(data, offset + 10)
            let flags = read16(data, offset + 8)
            guard flags & 0x1 == 0 else { throw Failure.unsupported("the archive is encrypted") }
            let compressed = Int(read32(data, offset + 20))
            let uncompressed = Int(read32(data, offset + 24))
            let nameLength = Int(read16(data, offset + 28))
            let extraLength = Int(read16(data, offset + 30))
            let commentLength = Int(read16(data, offset + 32))
            let localOffset = Int(read32(data, offset + 42))

            let nameStart = offset + 46
            guard nameStart + nameLength <= data.count else { break }
            let name = String(decoding: data[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            found[name] = Entry(name: name, localHeaderOffset: localOffset,
                                compressionMethod: method,
                                compressedSize: compressed, uncompressedSize: uncompressed)
            offset = nameStart + nameLength + extraLength + commentLength
        }
        return found
    }

    /// The decompressed bytes of one entry, or nil if it isn't there.
    static func read(_ name: String, from url: URL, entries: [String: Entry]) throws -> Data? {
        guard let entry = entries[name] else { return nil }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)

        // The central directory's name/extra lengths need not match the local
        // header's, so the data offset must come from the LOCAL header.
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, read32(data, header) == 0x04034b50 else {
            throw Failure.unsupported("a damaged local header")
        }
        let nameLength = Int(read16(data, header + 26))
        let extraLength = Int(read16(data, header + 28))
        let start = header + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= data.count else {
            throw Failure.unsupported("an entry that runs past the end of the file")
        }
        let payload = data[start..<(start + entry.compressedSize)]

        switch entry.compressionMethod {
        case 0:  return Data(payload)
        case 8:  return inflate(Data(payload), expected: entry.uncompressedSize)
        default: throw Failure.unsupported("compression method \(entry.compressionMethod)")
        }
    }

    /// Raw DEFLATE. Apple's COMPRESSION_ZLIB is headerless deflate, which is
    /// exactly what a ZIP entry stores.
    static func inflate(_ data: Data, expected: Int) -> Data? {
        guard !data.isEmpty else { return Data() }
        // A zero uncompressedSize can mean "streamed"; allow room to grow.
        let capacity = max(expected, data.count * 8, 64 * 1024)
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, capacity, s, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return out.prefix(written)
    }

    // MARK: - Byte access

    private static func endOfCentralDirectory(in data: Data) -> Int? {
        // Scan back from the end: the record is last, but a trailing comment of
        // up to 64 KB can sit after it.
        let minimum = 22
        guard data.count >= minimum else { return nil }
        let limit = max(0, data.count - minimum - 65_536)
        var i = data.count - minimum
        while i >= limit {
            if read32(data, i) == 0x06054b50 { return i }
            i -= 1
        }
        return nil
    }

    private static func read16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    private static func read32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base]) | UInt32(data[base + 1]) << 8
            | UInt32(data[base + 2]) << 16 | UInt32(data[base + 3]) << 24
    }
}
