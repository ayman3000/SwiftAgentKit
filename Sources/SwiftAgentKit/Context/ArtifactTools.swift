//
//  ArtifactTools.swift
//  SwiftAgentKit
//
//  Retrieval tools the model uses to pull full tool outputs back from the
//  `ArtifactStore` when a receipt in the ledger isn't enough.
//

import Foundation

/// Read the full stored output of a previous tool call, by artifact id.
public struct ArtifactReadTool: AgentTool {
    public let name = "artifact_read"
    public var isReadOnly: Bool { true }
    public let description = """
    Read the full stored output of a previous tool call by its artifact id \
    (shown in brackets in the tool ledger, e.g. artifact-abc123). Use `offset` \
    and `limit` to page through large outputs.
    """
    public let parameters = ToolParameters(
        properties: [
            "artifact_id": ToolParameterProperty(type: "string", description: "The artifact id, e.g. artifact-abc123"),
            "offset": ToolParameterProperty(type: "integer", description: "Start character offset (default 0)"),
            "limit": ToolParameterProperty(type: "integer", description: "Max characters to read (default 24000 — usually the whole artifact in one call)"),
        ],
        required: ["artifact_id"]
    )

    private let store: any ArtifactStore

    public init(store: any ArtifactStore) {
        self.store = store
    }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let id = parameters["artifact_id"] as? String, !id.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "artifact_read requires an artifact_id.")
        }
        let offset = intValue(parameters["offset"]) ?? 0
        // Default high so retrieval is single-shot for typical outputs — paginated
        // reads (repeated "call again with offset…") can make weaker models loop.
        let limit = intValue(parameters["limit"]) ?? 24_000

        guard let slice = await store.read(id, offset: offset, limit: limit) else {
            return .error(toolCallId: "", toolName: name, message: "Unknown artifact: \(id)")
        }
        let more = slice.hasMore
            ? "\n… [truncated — call again with offset \(slice.offset + slice.content.count)]"
            : ""
        return .success(toolCallId: "", toolName: name, result: slice.content + more)
    }
}

/// Search within a stored tool output for lines matching one or more
/// substrings, with surrounding context lines.
public struct ArtifactSearchTool: AgentTool {
    public let name = "artifact_search"
    public var isReadOnly: Bool { true }
    public let description = """
    Search a previous tool call's full output for lines containing substrings. \
    Pass ALL the terms you want to check in ONE call via `queries` (e.g. \
    ["error:", "TEST FAILED", "warning"]) instead of one call per term. Returns \
    matching lines with 2 lines of context each. Use the artifact id from the \
    tool ledger.
    """
    public let parameters = ToolParameters(
        properties: [
            "artifact_id": ToolParameterProperty(type: "string", description: "The artifact id, e.g. artifact-abc123"),
            "queries": ToolParameterProperty(type: "array", description: "Substrings to search for (case-insensitive) — batch every term you want to check into one call", itemsType: "string"),
            "query": ToolParameterProperty(type: "string", description: "Single substring to search for (alternative to `queries`)"),
            "max_matches": ToolParameterProperty(type: "integer", description: "Maximum matches per query (default 10)"),
        ],
        required: ["artifact_id"]
    )

    /// Context lines shown above and below each match.
    static let contextLines = 2

    private let store: any ArtifactStore

    public init(store: any ArtifactStore) {
        self.store = store
    }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let id = parameters["artifact_id"] as? String, !id.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "artifact_search requires an artifact_id.")
        }
        var queries: [String] = []
        if let list = parameters["queries"] as? [Any] {
            queries = list.compactMap { $0 as? String }.filter { !$0.isEmpty }
        }
        if let single = parameters["query"] as? String, !single.isEmpty {
            queries.append(single)
        }
        guard !queries.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "artifact_search requires `queries` (array) or `query` (string).")
        }
        let maxMatches = intValue(parameters["max_matches"]) ?? 10

        guard let artifact = await store.get(id) else {
            return .error(toolCallId: "", toolName: name, message: "Unknown artifact: \(id)")
        }
        let rendered = Self.render(content: artifact.content,
                                   queries: queries,
                                   maxMatchesPerQuery: maxMatches,
                                   artifactID: id)
        return .success(toolCallId: "", toolName: name, result: rendered)
    }

    /// Render grouped, contextual matches for each query. Pure so it's testable.
    static func render(content: String, queries: [String], maxMatchesPerQuery: Int, artifactID: String) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let lowered = lines.map { $0.lowercased() }
        var sections: [String] = []
        for query in queries {
            let needle = query.lowercased()
            var matchIndices: [Int] = []
            for (index, line) in lowered.enumerated() where line.contains(needle) {
                matchIndices.append(index)
                if matchIndices.count >= maxMatchesPerQuery { break }
            }
            if matchIndices.isEmpty {
                sections.append("\"\(query)\": no matches")
                continue
            }
            var blocks: [String] = []
            for match in matchIndices {
                let lo = max(0, match - contextLines)
                let hi = min(lines.count - 1, match + contextLines)
                let block = (lo...hi).map { i in
                    let marker = i == match ? ">" : " "
                    return "\(marker) L\(i + 1): \(lines[i].prefix(500))"
                }.joined(separator: "\n")
                blocks.append(block)
            }
            sections.append("\"\(query)\" — \(matchIndices.count) match\(matchIndices.count == 1 ? "" : "es"):\n" + blocks.joined(separator: "\n…\n"))
        }
        return "Results in \(artifactID):\n\n" + sections.joined(separator: "\n\n")
    }
}

/// List stored tool outputs (including prior sessions, when the store is
/// file-backed) so the model can discover retrievable history on demand.
public struct ArtifactListTool: AgentTool {
    public let name = "artifact_list"
    public var isReadOnly: Bool { true }
    public let description = """
    List stored outputs of previous tool calls in this conversation — \
    including ones from earlier sessions. Returns id, tool, description, age \
    and size; use artifact_read or artifact_search with an id to retrieve one.
    """
    public let parameters = ToolParameters(
        properties: [
            "limit": ToolParameterProperty(type: "integer", description: "Maximum entries, newest first (default 25)"),
        ],
        required: []
    )

    private let store: any ListableArtifactStore

    public init(store: any ListableArtifactStore) {
        self.store = store
    }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let limit = intValue(parameters["limit"]) ?? 25
        let summaries = await store.list(limit: limit)
        guard !summaries.isEmpty else {
            return .success(toolCallId: "", toolName: name, result: "No stored outputs for this conversation.")
        }
        let now = Date()
        let lines = summaries.map { summary in
            let age = Self.ageLabel(from: summary.createdAt, to: now)
            let tool = summary.toolName ?? "tool"
            return "\(summary.id) — \(tool) — \(summary.description) — \(age) — \(summary.byteCount) bytes"
        }
        return .success(toolCallId: "", toolName: name, result: lines.joined(separator: "\n"))
    }

    static func ageLabel(from created: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(created))
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }
}

// Tool arguments arrive as Int or Double depending on JSON decoding.
private func intValue(_ value: Any?) -> Int? {
    if let i = value as? Int { return i }
    if let d = value as? Double { return Int(d) }
    if let s = value as? String, let i = Int(s) { return i }
    return nil
}
