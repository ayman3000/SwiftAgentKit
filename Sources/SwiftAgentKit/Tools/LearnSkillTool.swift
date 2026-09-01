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
    correcting a mistake, so the lesson sticks. Provide a short `name`, a one- \
    line `description` (this is how the skill is found later — say what task it \
    is for, not how it works), and clear step-by-step `instructions`. Don't ask \
    permission — just save it.
    """

    public let parameters = ToolParameters(
        properties: [
            "name": ToolParameterProperty(type: "string", description: "Short skill name, e.g. \"scaffold swiftui view\"."),
            "description": ToolParameterProperty(type: "string", description: "One line saying what task this skill is for — shown in the skills index the model reads."),
            "instructions": ToolParameterProperty(type: "string", description: "Step-by-step instructions for the task."),
        ],
        required: ["name", "description", "instructions"]
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
        let skillDescription = (parameters["description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // AgentSkill.init derives a description from the body when the model
        // omits one — a skill must never be invisible in the index.
        let skill = AgentSkill(name: name, description: skillDescription,
                               instructions: instructions)
        do {
            try await store.save(skill)
        } catch {
            return .error(toolCallId: "", toolName: name, message: "Failed to save skill: \(error.localizedDescription)")
        }
        // Make it live immediately (replace any prior skill with the same name).
        await registry.unregister(named: name)
        await registry.register(skill)

        return .success(toolCallId: "", toolName: name,
                        result: "Learned skill \"\(name)\" — \(skill.description). Load it later with use_skill.")
    }
}
