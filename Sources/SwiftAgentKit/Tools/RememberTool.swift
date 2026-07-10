//
//  RememberTool.swift
//  SwiftAgentKit
//
//  A built-in tool for persisting durable knowledge to an AgentMemoryStore.
//
//  Generalized from production agent memory patterns. When an agent has a
//  memory store attached, it can call `remember` to save facts about the user
//  or the world, which are then injected into future system prompts.
//

import Foundation

/// A built-in tool that persists durable facts to an `AgentMemoryStore`.
///
/// Apps attach a memory store to an `Agent` via `agent.memoryStore = ...`.
/// If a store is present, the agent auto-registers this tool so the model can
/// save memories without asking permission first (writes are confined to the
/// configured store directory, never the user's files).
///
public final class RememberTool: AgentTool, @unchecked Sendable {

    public let name = "remember"

    public let description = """
    Save something durable to your persistent memory so you recall it in future \
    conversations. Use `kind: "user"` for facts about the user (name, role, \
    standing preferences) — these update USER.md. Use `kind: "fact"` for a \
    discrete piece of knowledge (a project's location, a decision, a convention) \
    — these become their own memory file. Use `kind: "agent"` to update your own \
    identity or principles. Call this whenever the user shares something worth \
    remembering; do NOT ask permission first.
    """

    public let parameters = ToolParameters(
        properties: [
            "kind": ToolParameterProperty(
                type: "string",
                description: "\"user\" for a user fact, \"fact\" for a discrete memory, or \"agent\" to update your own soul.",
                enum: ["user", "fact", "agent"]
            ),
            "title": ToolParameterProperty(
                type: "string",
                description: "Short label. For user facts it's the key (e.g. \"Name\"); for facts it's the memory title; for agent it's the updated section name."
            ),
            "content": ToolParameterProperty(
                type: "string",
                description: "The value/detail to remember."
            )
        ],
        required: ["kind", "title", "content"]
    )

    private let store: any AgentMemoryStore

    public init(store: any AgentMemoryStore) {
        self.store = store
    }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let kindStr = parameters["kind"] as? String,
              let kind = AgentMemoryKind(rawValue: kindStr),
              let title = parameters["title"] as? String, !title.isEmpty,
              let content = parameters["content"] as? String, !content.isEmpty
        else {
            return .error(
                toolCallId: "",
                toolName: name,
                message: "Error: `kind` (\"user\"|\"fact\"|\"agent\"), `title`, and `content` are all required."
            )
        }

        let entry = AgentMemoryEntry(kind: kind, title: title, content: content)
        do {
            try await store.save(entry)
            return .success(toolCallId: "", toolName: name, result: "Remembered \(kind.rawValue) fact: \(title)")
        } catch {
            return .error(toolCallId: "", toolName: name, message: "Error saving memory: \(error.localizedDescription)")
        }
    }
}
