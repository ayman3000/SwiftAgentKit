//
//  UpdateAgentProfileTool.swift
//  SwiftAgentKit
//
//  The only way the model changes AGENT.md: one section, on the user's
//  explicit request. Not auto-registered — the app registers it with an
//  `onChange` that records the change so the user can undo it.
//

import Foundation

public final class UpdateAgentProfileTool: AgentTool, @unchecked Sendable {

    public let name = "update_agent_profile"

    public let description = """
    Change your own profile (AGENT.md) — ONLY when the user explicitly asks \
    you to: a new name or nickname ("call yourself Nemo"), how to address \
    them, a different tone ("be more formal"), or a standing principle they \
    want you to follow. Never on your own initiative, and never to save \
    lessons or facts (use `remember` for those). `section` "identity" takes \
    lines like "Name: Nemo" — each replaces the line with the same label and \
    other lines stay; "tone" replaces the tone text; "principles" adds one \
    principle. Nothing else in the profile changes. The change applies from \
    your next reply and the user can undo it.
    """

    public let parameters = ToolParameters(
        properties: [
            "section": ToolParameterProperty(
                type: "string",
                description: "\"identity\", \"tone\" or \"principles\".",
                enum: ["identity", "tone", "principles"]
            ),
            "change": ToolParameterProperty(
                type: "string",
                description: "identity: \"Label: value\" lines. tone: the new tone. principles: the one principle to add."
            )
        ],
        required: ["section", "change"]
    )

    /// The mission is the app's and the user's to edit, never the model's.
    public static let editableSections: [AgentProfileSection] = [.identity, .tone, .principles]
    /// Longest `change` accepted, in characters.
    public static let maxChangeLength = 1000

    private let store: FileAgentMemoryStore
    private let onChange: @Sendable (AgentProfileSection, MemoryChange) async -> Void

    public init(store: FileAgentMemoryStore,
                onChange: @escaping @Sendable (AgentProfileSection, MemoryChange) async -> Void = { _, _ in }) {
        self.store = store
        self.onChange = onChange
    }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let raw = parameters["section"] as? String,
              let section = AgentProfileSection(rawValue: raw.lowercased()),
              Self.editableSections.contains(section),
              let change = (parameters["change"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !change.isEmpty
        else {
            return .error(toolCallId: "", toolName: name,
                          message: "Error: `section` (\"identity\", \"tone\" or \"principles\") and `change` are required.")
        }
        guard change.count <= Self.maxChangeLength else {
            return .error(toolCallId: "", toolName: name,
                          message: "Error: `change` is \(change.count) characters; the most is \(Self.maxChangeLength). Keep it to the one change the user asked for.")
        }
        // A line starting with `#` would become a heading in AGENT.md and
        // could replace or duplicate another section (e.g. the mission).
        if change.components(separatedBy: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }) {
            return .error(toolCallId: "", toolName: name,
                          message: "Error: `change` must not contain lines starting with `#` (headings). Give only the text of the \(section.rawValue) section.")
        }
        let store = self.store
        do {
            let memoryChange = try await MemoryFileWork.run {
                try store.editAgentProfile(section: section, change: change)
            }
            await onChange(section, memoryChange)
            let now = MemoryDocuments.agentSection(section, in: memoryChange.after ?? "") ?? change
            return .success(toolCallId: "", toolName: name, result: "Updated \(section.heading):\n\(now)")
        } catch {
            return .error(toolCallId: "", toolName: name,
                          message: "Error updating the profile: \(error.localizedDescription)")
        }
    }
}
