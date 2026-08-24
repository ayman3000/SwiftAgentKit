//
//  FileArtifactStore.swift
//  SwiftAgentKit
//
//  Two-tier artifact store: an in-memory tier holds EVERYTHING for the running
//  session (same behavior as InMemoryArtifactStore), while a disk tier persists
//  the subset approved by `persistFilter` so tool history survives restarts —
//  retrieved strictly on demand via artifact_list/artifact_read.
//

import Foundation

public actor FileArtifactStore: ArtifactStore, ListableArtifactStore {

    /// Persisted sidecar metadata (`<id>.json`); content lives in `<id>.txt`.
    private struct Meta: Codable {
        let id: String
        let toolCallID: String?
        let toolName: String?
        let description: String
        let byteCount: Int
        let createdAt: Date
    }

    private let directory: URL
    private let persistFilter: @Sendable (String?) -> Bool
    private let maxBytes: Int

    /// Session tier: every artifact saved this session (also acts as a read
    /// cache for disk artifacts already touched).
    private var memory: [String: Artifact] = [:]
    /// Disk tier index, loaded once at init; content is lazy-loaded on demand.
    private var diskIndex: [String: Meta] = [:]

    /// - Parameters:
    ///   - directory: per-scope folder (e.g. per conversation); created if needed.
    ///   - persistFilter: given the producing tool's name (nil for unknown),
    ///     decides whether the artifact is written to disk. Default: persist all.
    ///   - maxBytes: disk budget for this directory; oldest artifacts are
    ///     evicted first when exceeded.
    public init(directory: URL,
                persistFilter: @escaping @Sendable (String?) -> Bool = { _ in true },
                maxBytes: Int = 25_000_000) {
        self.directory = directory
        self.persistFilter = persistFilter
        self.maxBytes = maxBytes
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Load the metadata index (cheap: sidecars only, no content).
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecars = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
        for url in sidecars {
            if let data = try? Data(contentsOf: url),
               let meta = try? decoder.decode(Meta.self, from: data) {
                diskIndex[meta.id] = meta
            }
        }
    }

    // MARK: - ArtifactStore

    public func save(_ content: String, description: String, toolCallID: String?, toolName: String?) -> Artifact {
        let id = "artifact-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12)
        let artifact = Artifact(id: String(id), toolCallID: toolCallID, toolName: toolName,
                                description: description, content: content)
        memory[artifact.id] = artifact
        if persistFilter(toolName) {
            persist(artifact)
            enforceBudget()
        }
        return artifact
    }

    public func get(_ id: String) -> Artifact? {
        if let cached = memory[id] { return cached }
        guard let meta = diskIndex[id], let loaded = loadContent(id: id, meta: meta) else { return nil }
        memory[id] = loaded   // cache so repeated reads skip disk
        return loaded
    }

    public func read(_ id: String, offset: Int, limit: Int) -> ArtifactSlice? {
        guard let artifact = get(id) else { return nil }
        let chars = Array(artifact.content)
        let total = chars.count
        let start = max(0, min(offset, total))
        let end = max(start, min(start + max(0, limit), total))
        return ArtifactSlice(artifactID: id, offset: start, content: String(chars[start..<end]),
                             hasMore: end < total, totalCharacters: total)
    }

    public func search(_ id: String, query: String, maxMatches: Int) -> [ArtifactMatch] {
        guard let artifact = get(id), !query.isEmpty else { return [] }
        let needle = query.lowercased()
        var matches: [ArtifactMatch] = []
        for (index, line) in artifact.content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.lowercased().contains(needle) {
                matches.append(ArtifactMatch(line: index + 1, text: String(line.prefix(500))))
                if matches.count >= maxMatches { break }
            }
        }
        return matches
    }

    // MARK: - ListableArtifactStore

    public func list(limit: Int) -> [ArtifactSummary] {
        // Merge both tiers (memory wins on id collision), newest first.
        var byID: [String: ArtifactSummary] = [:]
        for meta in diskIndex.values {
            byID[meta.id] = ArtifactSummary(id: meta.id, toolName: meta.toolName,
                                            description: meta.description,
                                            byteCount: meta.byteCount, createdAt: meta.createdAt)
        }
        for artifact in memory.values {
            byID[artifact.id] = ArtifactSummary(id: artifact.id, toolName: artifact.toolName,
                                                description: artifact.description,
                                                byteCount: artifact.byteCount, createdAt: artifact.createdAt)
        }
        return byID.values.sorted { $0.createdAt > $1.createdAt }.prefix(max(0, limit)).map { $0 }
    }

    // MARK: - Disk tier

    private func contentURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".txt") }
    private func metaURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".json") }

    private func persist(_ artifact: Artifact) {
        let meta = Meta(id: artifact.id, toolCallID: artifact.toolCallID, toolName: artifact.toolName,
                        description: artifact.description, byteCount: artifact.byteCount,
                        createdAt: artifact.createdAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Content FIRST, sidecar last — an index entry must never point at a
        // missing file. Failures leave the artifact memory-only (session intact).
        do {
            try artifact.content.write(to: contentURL(artifact.id), atomically: true, encoding: .utf8)
            try encoder.encode(meta).write(to: metaURL(artifact.id), options: .atomic)
            diskIndex[artifact.id] = meta
        } catch {
            try? FileManager.default.removeItem(at: contentURL(artifact.id))
        }
    }

    private func loadContent(id: String, meta: Meta) -> Artifact? {
        guard let content = try? String(contentsOf: contentURL(id), encoding: .utf8) else {
            // Corrupt/missing content → drop the dangling index entry.
            diskIndex[id] = nil
            try? FileManager.default.removeItem(at: metaURL(id))
            return nil
        }
        return Artifact(id: id, toolCallID: meta.toolCallID, toolName: meta.toolName,
                        description: meta.description, content: content, createdAt: meta.createdAt)
    }

    private func enforceBudget() {
        var total = diskIndex.values.reduce(0) { $0 + $1.byteCount }
        guard total > maxBytes else { return }
        for meta in diskIndex.values.sorted(by: { $0.createdAt < $1.createdAt }) {
            try? FileManager.default.removeItem(at: contentURL(meta.id))
            try? FileManager.default.removeItem(at: metaURL(meta.id))
            diskIndex[meta.id] = nil
            total -= meta.byteCount
            if total <= maxBytes { break }
        }
    }
}
