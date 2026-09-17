//
//  PDFOCRCache.swift
//  SwiftAgentKitTools
//
//  Disk cache for OCR'd PDF pages.
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Caches the text Vision recognised for a scanned PDF page.
///
/// Recognition costs roughly 700 ms a page — 14 seconds for a 20-page call — so
/// re-reading a scanned document is the one genuinely expensive thing PDF
/// extraction does. Text-layer extraction runs in milliseconds and is
/// deliberately NOT cached: a cache there would save ~0.1% of a turn while
/// adding a store and an invalidation story.
///
/// Keyed by the file's SHA-256 and the page number, so the same document
/// recognised once is free everywhere afterwards — a second conversation, a
/// second copy of the file, a different path. Content addressing also means
/// there is nothing to invalidate: different bytes are a different key.
public struct PDFOCRCache: Sendable {
    public let directory: URL?

    /// - Parameter directory: where to keep entries. nil disables the cache.
    public init(directory: URL? = PDFOCRCache.defaultDirectory()) {
        self.directory = directory
    }

    public static func defaultDirectory() -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("SwiftAgentKit/pdf-ocr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func url(digest: String, page: Int) -> URL? {
        directory?.appendingPathComponent("\(digest)-\(page).txt")
    }

    public func text(digest: String, page: Int) -> String? {
        guard let url = url(digest: digest, page: page) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    public func store(_ text: String, digest: String, page: Int) {
        guard let url = url(digest: digest, page: page) else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// SHA-256 of a file, streamed in chunks so a 100 MB PDF is not read into
    /// memory just to be identified.
    public static func digest(ofFileAt path: String) -> String? {
        #if canImport(CryptoKit)
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }
}
