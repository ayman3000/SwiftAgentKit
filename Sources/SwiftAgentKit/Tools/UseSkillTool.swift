//
//  UseSkillTool.swift
//  SwiftAgentKit
//
//  On-demand skill loading — the second half of model-driven skill
//  selection. The system prompt carries the index (name — description);
//  this tool returns a skill's full instructions when the model decides
//  one fits the task. Read-only: no store writes, no approval gate.
//

import Foundation

/// Loads a skill's full instructions by name. Auto-registered alongside
/// `learn_skill` when a skill store is attached.
public final class UseSkillTool: AgentTool, @unchecked Sendable {

    public let name = "use_skill"

    public var isReadOnly: Bool { true }

    public let description = """
    Load a skill's full instructions by name. The skills index in your \
    system prompt lists every available skill with a one-line description — \
    when a task matches one, call this BEFORE starting the task and follow \
    the loaded instructions.
    """

    public let parameters = ToolParameters(
        properties: [
            "name": ToolParameterProperty(type: "string", description: "Exact skill name from the skills index."),
        ],
        required: ["name"]
    )

    private let registry: SkillRegistry

    public init(registry: SkillRegistry) {
        self.registry = registry
    }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let skillName = (parameters["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !skillName.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "use_skill requires `name`.")
        }
        if let skill = await registry.skill(named: skillName) {
            return .success(toolCallId: "", toolName: name, result: skill.render())
        }
        // Unknown name: return the index so the model self-corrects in one step.
        let available = await registry.allSkills()
            .map { $0.name }.sorted().joined(separator: ", ")
        let hint = available.isEmpty ? "No skills are available." : "Available skills: \(available)."
        return .error(toolCallId: "", toolName: name,
                      message: "No skill named \"\(skillName)\". \(hint)")
    }
}
