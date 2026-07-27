//
//  ArtifactStore.swift
//  SwiftAgentKit
//
//  ContextSift-style external memory: full tool outputs are stored here so they
//  can be removed from active model context (replaced by a compact receipt) yet
//  retrieved losslessly on demand. Removing a result from context ≠ deleting it.
//

import Foundation

/// A stored tool output. The full content lives here while a compact receipt
/// stands in for it inside the model's active context.
public struct Artifact: Sendable, Identifiable, Equatable {
    public let id: String
    public let toolCallID: String?
    public let description: String
    public let content: String
    public let byteCount: Int
    public let createdAt: Date

    public init(id: String, toolCallID: String?, description: String, content: String, createdAt: Date = Date()) {
        self.id = id
        self.toolCallID = toolCallID
        self.description = description
        self.content = content
        self.byteCount = content.utf8.count
        self.createdAt = createdAt
    }
}

/// A bounded slice of an artifact returned by `read`.
public struct ArtifactSlice: Sendable, Equatable {
    public let artifactID: String
    public let offset: Int
    public let content: String
    public let hasMore: Bool
    public let totalCharacters: Int

    public init(artifactID: String, offset: Int, content: String, hasMore: Bool, totalCharacters: Int) {
        self.artifactID = artifactID
        self.offset = offset
        self.content = content
        self.hasMore = hasMore
        self.totalCharacters = totalCharacters
    }
}

/// A line match inside an artifact returned by `search`.
public struct ArtifactMatch: Sendable, Equatable {
    public let line: Int
    public let text: String
    public init(line: Int, text: String) {
        self.line = line
        self.text = text
    }
}

/// Lossless external store for full tool outputs. Implement to back it with the
/// filesystem, a database, etc. The default `InMemoryArtifactStore` keeps them
/// in memory for the process lifetime.
public protocol ArtifactStore: Sendable {
    /// Store a full output and return its artifact record (with a fresh id).
    func save(_ content: String, description: String, toolCallID: String?) async -> Artifact
    /// Fetch a stored artifact by id.
    func get(_ id: String) async -> Artifact?
    /// Read a bounded character range of an artifact.
    func read(_ id: String, offset: Int, limit: Int) async -> ArtifactSlice?
    /// Line-level substring search within an artifact.
    func search(_ id: String, query: String, maxMatches: Int) async -> [ArtifactMatch]
}

/// In-memory artifact store (process lifetime). Good for apps and tests; swap in
/// a file-backed store for durability.
public actor InMemoryArtifactStore: ArtifactStore {
    private var artifacts: [String: Artifact] = [:]

    public init() {}

    public func save(_ content: String, description: String, toolCallID: String?) -> Artifact {
        let id = "artifact-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12)
        let artifact = Artifact(id: String(id), toolCallID: toolCallID, description: description, content: content)
        artifacts[artifact.id] = artifact
        return artifact
    }

    public func get(_ id: String) -> Artifact? {
        artifacts[id]
    }

    public func read(_ id: String, offset: Int, limit: Int) -> ArtifactSlice? {
        guard let artifact = artifacts[id] else { return nil }
        let chars = Array(artifact.content)
        let total = chars.count
        let start = max(0, min(offset, total))
        let end = max(start, min(start + max(0, limit), total))
        let slice = String(chars[start..<end])
        return ArtifactSlice(
            artifactID: id,
            offset: start,
            content: slice,
            hasMore: end < total,
            totalCharacters: total
        )
    }

    public func search(_ id: String, query: String, maxMatches: Int) -> [ArtifactMatch] {
        guard let artifact = artifacts[id], !query.isEmpty else { return [] }
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
}
