//
//  AgentSkill.swift
//  SwiftAgentKit
//
//  Model-driven skill selection. The system prompt carries a compact,
//  always-present INDEX of every skill (one line: name — description);
//  the model loads a skill's full instructions on demand with the
//  `use_skill` tool. The MODEL chooses skills by meaning.
//
//  History: selection used to be keyword-trigger matching against the
//  user's query. That failed exactly when intent was phrased in words a
//  skill author didn't predict ("let's brainstorm" found nothing), and
//  the model could never reach for a skill mid-task. Triggers survive
//  only as parsed-but-unused file metadata for compatibility.
//
//  Progressive disclosure is preserved where it matters: the index costs
//  ~15 tokens per skill; a skill's full body enters context only in the
//  conversations that actually load it.
//

import Foundation

/// A named block of instructions the model can load on demand via
/// `use_skill`. The `description` is the skill's entire discoverability
/// surface — it is what the model reads in the index when deciding
/// whether the skill fits the task.
public struct AgentSkill: Sendable, Identifiable, Equatable {

    public let id: String
    public var name: String
    /// One-line summary shown in the system-prompt index. Required for
    /// discoverability; derived from the body's first line for legacy
    /// skill files that predate the field.
    public var description: String
    /// Legacy metadata (pre-index selection). Parsed and preserved so old
    /// skill files round-trip, but NOT used for selection.
    public var triggerKeywords: [String]
    public var instructions: String

    /// Optional tier gate (e.g. ".free", ".pro") — apps can filter skills by tier.
    public var tier: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        description: String = "",
        triggerKeywords: [String] = [],
        instructions: String,
        tier: String? = nil
    ) {
        self.id = id
        self.name = name
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        self.description = trimmed.isEmpty
            ? Self.derivedDescription(from: instructions) : trimmed
        self.triggerKeywords = triggerKeywords
        self.instructions = instructions
        self.tier = tier
    }

    /// Fallback description for skills authored before the field existed:
    /// the first non-empty instruction line, flattened, capped at 120 chars.
    public static func derivedDescription(from instructions: String) -> String {
        let firstLine = instructions
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return String(firstLine.prefix(120))
    }

    /// Render the skill's full instructions for a `use_skill` load.
    public func render() -> String {
        """
        [Skill "\(name)" loaded — follow these instructions for this task:]
        \(instructions)
        """
    }

    /// The skill's single line in the system-prompt index.
    public func indexLine() -> String {
        "- \(name) — \(description)"
    }
}

/// A registry of skills backing the system-prompt index and `use_skill`.
///
/// Thread-safe via actor isolation. The index is query-independent and
/// byte-stable (alphabetical) so the system prompt stays cache-friendly
/// across steps; it only changes when skills are added or removed.
public actor SkillRegistry {

    private var skills: [AgentSkill] = []
    private var tierFilter: String?

    public init() {}

    /// Register a skill.
    public func register(_ skill: AgentSkill) {
        skills.append(skill)
    }

    /// Register multiple skills.
    public func registerAll(_ skills: [AgentSkill]) {
        self.skills.append(contentsOf: skills)
    }

    /// Unregister a skill by name.
    public func unregister(named name: String) {
        skills.removeAll { $0.name == name }
    }

    /// Set a tier filter (only skills matching this tier, or with no tier, will be active).
    public func setTierFilter(_ tier: String?) {
        tierFilter = tier
    }

    /// Get all registered skills (respecting tier filter).
    public func allSkills() -> [AgentSkill] {
        filteredByTier(skills)
    }

    /// Resolve a skill by exact name (respecting tier filter) — the
    /// `use_skill` lookup. A tier-hidden skill is unloadable, not just
    /// invisible.
    public func skill(named name: String) -> AgentSkill? {
        filteredByTier(skills).first { $0.name == name }
    }

    /// The always-present system-prompt index: one line per skill,
    /// alphabetical by name (byte-stable for prompt caching). Empty
    /// string when no skills are registered.
    public func skillIndex() -> String {
        let visible = filteredByTier(skills).sorted { $0.name < $1.name }
        guard !visible.isEmpty else { return "" }
        return """

        Skills — reusable procedures. BEFORE starting a task that matches one, \
        load it with `use_skill(name)` and follow it:
        \(visible.map { $0.indexLine() }.joined(separator: "\n"))
        """
    }

    /// Clear all skills.
    public func clear() {
        skills.removeAll()
    }

    // MARK: - Private

    private func filteredByTier(_ skills: [AgentSkill]) -> [AgentSkill] {
        guard let tierFilter else { return skills }
        return skills.filter { $0.tier == nil || $0.tier == tierFilter }
    }
}
