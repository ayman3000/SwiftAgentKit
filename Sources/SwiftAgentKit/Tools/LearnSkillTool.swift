//
//  LearnSkillTool.swift
//  SwiftAgentKit
//
//  Lets the agent author a reusable skill at runtime — persisting it and adding
//  it to the live `SkillRegistry` so it activates immediately and in future
//  sessions. The self-improvement counterpart to `RememberTool`.
//

import Foundation

/// A built-in tool the agent calls to turn a recurring task (or a corrected
/// mistake) into a reusable, keyword-triggered skill.
///
/// Auto-registered by the agent when an `AgentSkillStore` is attached
/// (`agent.skillStore = …`). Saving persists to the store AND registers the
/// skill into the agent's live registry (so it can fire later in the same
/// session). Writes are confined to the store directory.
public final class LearnSkillTool: AgentTool, @unchecked Sendable {

    public let name = "learn_skill"

    public let description = """
    Save a reusable skill so you handle a recurring task better next time. Call \
    this after you work out how to do a repeatable multi-step task, or after \
    correcting a mistake, so the lesson sticks. Provide a short `name`, comma- \
    separated `triggers` (keywords that should activate it later), and clear \
    step-by-step `instructions`. Don't ask permission — just save it.
    """

    public let parameters = ToolParameters(
        properties: [
            "name": ToolParameterProperty(type: "string", description: "Short skill name, e.g. \"scaffold swiftui view\"."),
            "triggers": ToolParameterProperty(type: "string", description: "Comma-separated keywords that should activate this skill."),
            "instructions": ToolParameterProperty(type: "string", description: "Step-by-step instructions for the task."),
        ],
        required: ["name", "triggers", "instructions"]
    )

    private let store: any AgentSkillStore
    private let registry: SkillRegistry

    public init(store: any AgentSkillStore, registry: SkillRegistry) {
        self.store = store
        self.registry = registry
    }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let name = (parameters["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              let instructions = (parameters["instructions"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !instructions.isEmpty
        else {
            return .error(toolCallId: "", toolName: name, message: "learn_skill requires `name` and `instructions`.")
        }
        let triggers = Self.triggers(from: parameters["triggers"])

        let skill = AgentSkill(name: name, triggerKeywords: triggers, instructions: instructions)
        do {
            try await store.save(skill)
        } catch {
            return .error(toolCallId: "", toolName: name, message: "Failed to save skill: \(error.localizedDescription)")
        }
        // Make it live immediately (replace any prior skill with the same name).
        await registry.unregister(named: name)
        await registry.register(skill)

        let triggerList = triggers.isEmpty ? "(no triggers)" : triggers.joined(separator: ", ")
        return .success(toolCallId: "", toolName: name, result: "Learned skill \"\(name)\" (triggers: \(triggerList)).")
    }

    /// Accept comma-separated string or an array of strings.
    private static func triggers(from value: Any?) -> [String] {
        if let s = value as? String {
            return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let arr = value as? [Any] {
            return arr.compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return []
    }
}
