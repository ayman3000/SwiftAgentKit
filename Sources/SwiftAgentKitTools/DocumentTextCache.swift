//
//  DocumentTextCache.swift
//  SwiftAgentKitTools
//
//  Text pulled out of a document, kept by the document's content digest so
//  the same bytes are never extracted twice — by the same agent, a sub-agent,
//  or another conversation. An edited file has a new digest, so nothing here
//  can ever be stale. Bounded: past the cap, the oldest entries go first.
//
//  Office files are the ones worth caching: Word goes through AppKit, slides
//  and sheets through a ZIP parser. A PDF's text layer is already cheap to
//  read, and hashing a large PDF to save it would cost more than it saves;
//  scanned pages are cached separately by PDFOCRCache.
//

import CryptoKit
import Foundation

public struct DocumentTextCache: Sendable {
    public let directory: URL?
    /// Total bytes the cache may hold before the oldest entries are dropped.
    public let maxBytes: Int

    public init(directory: URL? = DocumentTextCache.defaultDirectory(), maxBytes: Int = 200 * 1024 * 1024) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    public static func defaultDirectory() -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("SwiftAgentKit/documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `key` names what was extracted: "docx", "pptx-1-0" (slides 1…end),
    /// "digest" for a reading-model digest, and so on.
    func url(digest: String, key: String) -> URL? {
        directory?.appendingPathComponent("\(digest)-\(key).txt")
    }

    public func text(digest: String, key: String) -> String? {
        guard let url = url(digest: digest, key: key) else { return nil }
        // Touch on read so eviction is least-recently-used, not oldest-written.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    public func store(_ text: String, digest: String, key: String) {
        guard let url = url(digest: digest, key: key) else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
        evictIfNeeded()
    }

    /// Drop least-recently-used entries until the cache fits its cap.
    func evictIfNeeded() {
        guard let directory else { return }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        var entries: [(URL, Int, Date)] = names.compactMap { name in
            let url = directory.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int,
                  let date = attrs[.modificationDate] as? Date else { return nil }
            return (url, size, date)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > maxBytes else { return }
        entries.sort { $0.2 < $1.2 }
        for (url, size, _) in entries where total > maxBytes {
            try? fm.removeItem(at: url)
            total -= size
        }
    }

    /// SHA-256 of a file, streamed in chunks.
    public static func digest(ofFileAt path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
