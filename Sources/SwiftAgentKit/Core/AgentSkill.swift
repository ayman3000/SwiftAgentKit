//
//  AgentSkill.swift
//  SwiftAgentKit
//
//  Progressive-disclosure skill system — injects instruction blocks into
//  the system prompt only when the query matches trigger keywords.
//
//  This keeps the token budget small for small/local models. Instead of
//  stuffing every instruction into the system prompt, skills are loaded
//  on demand based on what the user is actually asking about.
//
//  Example:
//  ```
//  AgentSkill(
//      name: "scaffolding",
//      triggerKeywords: ["scaffold", "create project", "new app", "xcode project"],
//      instructions: "When scaffolding a project: 1. Ask for project name. 2. Create directory. 3. Create Package.swift..."
//  )
//  ```
//
//  The skill is only injected when the user says "scaffold a new project" —
//  not when they ask "read this file". This saves hundreds of tokens per query.
//

import Foundation

/// A skill is a block of instructions injected into the system prompt
/// only when the user's query matches trigger keywords.
///
/// This is the **progressive disclosure** pattern — keep the system prompt
/// small by default, and only expand it when the user's query actually
/// needs specific domain knowledge.
///
public struct AgentSkill: Sendable, Identifiable, Equatable {

    public let id: String
    public var name: String
    public var triggerKeywords: [String]
    public var instructions: String

    /// Optional tier gate (e.g. ".free", ".pro") — apps can filter skills by tier.
    public var tier: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        triggerKeywords: [String],
        instructions: String,
        tier: String? = nil
    ) {
        self.id = id
        self.name = name
        self.triggerKeywords = triggerKeywords
        self.instructions = instructions
        self.tier = tier
    }

    /// Check if this skill should be activated for the given query.
    public func matches(_ query: String) -> Bool {
        let lowerQuery = query.lowercased()
        return triggerKeywords.contains { keyword in
            lowerQuery.contains(keyword.lowercased())
        }
    }

    /// Render the skill as an instruction block for the system prompt.
    public func render() -> String {
        """

        --- Skill: \(name) ---
        \(instructions)
        --- End Skill: \(name) ---

        """
    }
}

/// A registry of skills that handles progressive disclosure.
///
/// Thread-safe via actor isolation. The registry holds all skills,
/// and the agent queries it per-request to find which skills match
/// the current query. Only matching skills are injected into the
/// system prompt.
///
/// Usage:
/// ```swift
/// let registry = SkillRegistry()
/// await registry.register(AgentSkill(
///     name: "chart",
///     triggerKeywords: ["chart", "graph", "plot", "visualization"],
///     instructions: "When creating charts: use the Charts framework..."
/// ))
/// let active = await registry.matchingSkills(for: "Create a bar chart of sales data")
/// // → returns the chart skill
/// ```
///
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

    /// Find skills that match the given query (respecting tier filter).
    public func matchingSkills(for query: String) -> [AgentSkill] {
        let candidates = filteredByTier(skills)
        return candidates.filter { $0.matches(query) }
    }

    /// Build the system prompt augmentation for matching skills.
    /// Returns an empty string if no skills match.
    public func systemPromptAugmentation(for query: String) -> String {
        let matched = matchingSkills(for: query)
        guard !matched.isEmpty else { return "" }
        return matched.map { $0.render() }.joined()
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