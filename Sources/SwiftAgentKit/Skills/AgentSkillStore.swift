//
//  AgentSkillStore.swift
//  SwiftAgentKit
//
//  Persistence for `AgentSkill`s so an agent can *author* skills at runtime
//  (via `LearnSkillTool`) and reload them in future sessions — the substrate
//  for a self-improving agent that turns recurring tasks into reusable skills.
//

import Foundation

/// A store that persists `AgentSkill`s across sessions.
public protocol AgentSkillStore: Sendable {
    /// Persist a skill (overwrites an existing skill with the same name).
    func save(_ skill: AgentSkill) async throws
    /// Delete a skill by name.
    func delete(name: String) async throws
    /// Load every persisted skill.
    func loadAll() async throws -> [AgentSkill]
}

/// A markdown-backed skill store in a configurable directory. One file per skill:
///
///     <directory>/
///       <slug>.md
///
/// File format (human-editable):
///
///     # <name>
///     Triggers: keyword one, keyword two
///
///     <instructions…>
///
public final class FileAgentSkillStore: AgentSkillStore, @unchecked Sendable {

    public let directory: URL
    private let fileManager = FileManager.default
    /// Serializes mutating file I/O (no `await` held across the lock).
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Convenience: a store under the user's home, e.g. `~/.myagent/skills`.
    public static func defaultStore(named name: String) -> FileAgentSkillStore {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return FileAgentSkillStore(directory: home.appendingPathComponent(".\(name)/skills"))
    }

    public func save(_ skill: AgentSkill) async throws {
        try lock.withLock {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(Self.slugify(skill.name)).md")
            let triggers = skill.triggerKeywords.joined(separator: ", ")
            let body = "# \(skill.name)\nTriggers: \(triggers)\n\n\(skill.instructions)\n"
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public func delete(name: String) async throws {
        try lock.withLock {
            let url = directory.appendingPathComponent("\(Self.slugify(name)).md")
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    public func loadAll() async throws -> [AgentSkill] {
        let files = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return files
            .filter { $0.hasSuffix(".md") }
            .sorted()
            .compactMap { file -> AgentSkill? in
                guard let content = try? String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8) else {
                    return nil
                }
                return Self.parse(content)
            }
    }

    // MARK: - Parsing

    static func parse(_ markdown: String) -> AgentSkill? {
        var name: String?
        var triggers: [String] = []
        var instructionLines: [String] = []
        var inBody = false

        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if name == nil, trimmed.hasPrefix("# ") {
                name = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if !inBody {
                if trimmed.isEmpty { continue }   // skip blanks between title / triggers / body
                if trimmed.lowercased().hasPrefix("triggers:") {
                    let raw = trimmed.dropFirst("triggers:".count)
                    triggers = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    inBody = true
                    continue
                }
                inBody = true   // first non-empty, non-triggers line starts the body
            }
            instructionLines.append(line)
        }

        guard let name, !name.isEmpty else { return nil }
        let instructions = instructionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instructions.isEmpty else { return nil }
        return AgentSkill(name: name, triggerKeywords: triggers, instructions: instructions)
    }

    static func slugify(_ s: String) -> String {
        let mapped = s.lowercased().map { ($0.isLetter || $0.isNumber) ? $0 : "-" }
        let collapsed = String(mapped).replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "skill" : trimmed
    }
}
