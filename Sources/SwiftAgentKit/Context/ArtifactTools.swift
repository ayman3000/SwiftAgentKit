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
    public let description = """
    Read the full stored output of a previous tool call by its artifact id \
    (shown in brackets in the tool ledger, e.g. artifact-abc123). Use `offset` \
    and `limit` to page through large outputs.
    """
    public let parameters = ToolParameters(
        properties: [
            "artifact_id": ToolParameterProperty(type: "string", description: "The artifact id, e.g. artifact-abc123"),
            "offset": ToolParameterProperty(type: "integer", description: "Start character offset (default 0)"),
            "limit": ToolParameterProperty(type: "integer", description: "Max characters to read (default 8000)"),
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
        let limit = intValue(parameters["limit"]) ?? 8_000

        guard let slice = await store.read(id, offset: offset, limit: limit) else {
            return .error(toolCallId: "", toolName: name, message: "Unknown artifact: \(id)")
        }
        let more = slice.hasMore
            ? "\n… [truncated — call again with offset \(slice.offset + slice.content.count)]"
            : ""
        return .success(toolCallId: "", toolName: name, result: slice.content + more)
    }
}

/// Search within a stored tool output for lines matching a substring.
public struct ArtifactSearchTool: AgentTool {
    public let name = "artifact_search"
    public let description = """
    Search a previous tool call's full output for lines containing a substring. \
    Returns matching line numbers and text. Use the artifact id from the tool \
    ledger.
    """
    public let parameters = ToolParameters(
        properties: [
            "artifact_id": ToolParameterProperty(type: "string", description: "The artifact id, e.g. artifact-abc123"),
            "query": ToolParameterProperty(type: "string", description: "Substring to search for (case-insensitive)"),
            "max_matches": ToolParameterProperty(type: "integer", description: "Maximum matches to return (default 10)"),
        ],
        required: ["artifact_id", "query"]
    )

    private let store: any ArtifactStore

    public init(store: any ArtifactStore) {
        self.store = store
    }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let id = parameters["artifact_id"] as? String, !id.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "artifact_search requires an artifact_id.")
        }
        guard let query = parameters["query"] as? String, !query.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "artifact_search requires a query.")
        }
        let maxMatches = intValue(parameters["max_matches"]) ?? 10

        let matches = await store.search(id, query: query, maxMatches: maxMatches)
        if matches.isEmpty {
            return .success(toolCallId: "", toolName: name, result: "No matches for \"\(query)\" in \(id).")
        }
        let rendered = matches.map { "L\($0.line): \($0.text)" }.joined(separator: "\n")
        return .success(toolCallId: "", toolName: name, result: rendered)
    }
}

// Tool arguments arrive as Int or Double depending on JSON decoding.
private func intValue(_ value: Any?) -> Int? {
    if let i = value as? Int { return i }
    if let d = value as? Double { return Int(d) }
    if let s = value as? String, let i = Int(s) { return i }
    return nil
}
