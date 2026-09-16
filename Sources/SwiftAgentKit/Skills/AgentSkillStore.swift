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

/// A markdown-backed skill store in a configurable directory. One file per skill,
/// with an optional sibling directory holding the files that skill ships:
///
///     <directory>/
///       <slug>.md          the skill itself — instructions the model reads
///       <slug>/            optional: reference documents, templates, scripts
///
/// The file stays the skill. Bundled files sit beside it rather than inside a
/// restructured layout, so every skill written before this existed keeps
/// loading unchanged and there is no migration to get wrong.
///
/// File format (human-editable):
///
///     # <name>
///     Description: one line the model reads in the skills index
///     Triggers: legacy keyword one, keyword two   (parsed, unused)
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
            var header = "# \(skill.name)\nDescription: \(skill.description)\n"
            if !skill.triggerKeywords.isEmpty {
                header += "Triggers: \(skill.triggerKeywords.joined(separator: ", "))\n"
            }
            try (header + "\n\(skill.instructions)\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public func delete(name: String) async throws {
        try lock.withLock {
            let url = directory.appendingPathComponent("\(Self.slugify(name)).md")
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            // A deleted skill takes its files with it — otherwise scripts from a
            // removed skill stay on disk, and a later skill of the same name
            // inherits them.
            let resources = directory.appendingPathComponent(Self.slugify(name), isDirectory: true)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: resources.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                try fileManager.removeItem(at: resources)
            }
        }
    }

    public func loadAll() async throws -> [AgentSkill] {
        let files = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return files
            .filter { $0.hasSuffix(".md") }
            .sorted()
            .compactMap { file -> AgentSkill? in
                guard let content = try? String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8),
                      var skill = Self.parse(content) else {
                    return nil
                }
                skill.resourcesPath = resourcesDirectory(forFile: file)
                return skill
            }
    }

    /// The sibling directory holding a skill's bundled files, or nil when it
    /// ships none. Named from the file rather than the skill so a renamed
    /// skill cannot silently adopt another's files.
    private func resourcesDirectory(forFile file: String) -> String? {
        let slug = String(file.dropLast(3))          // trim ".md"
        let dir = directory.appendingPathComponent(slug, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return dir.path
    }

    /// Where a skill's bundled files belong. The caller creates and fills it;
    /// the store only says where.
    ///
    /// Always a subdirectory, never the store root: `slugify` substitutes a
    /// fallback for a name with nothing usable in it, so a blank name cannot
    /// resolve here to the directory that `delete` would then remove.
    public func resourcesDirectory(forSkillNamed name: String) -> URL {
        directory.appendingPathComponent(Self.slugify(name), isDirectory: true)
    }

    // MARK: - Parsing

    public static func parse(_ markdown: String) -> AgentSkill? {
        var name: String?
        var description = ""
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
                if trimmed.isEmpty { continue }   // skip blanks in the header block
                if trimmed.lowercased().hasPrefix("description:") {
                    description = String(trimmed.dropFirst("description:".count))
                        .trimmingCharacters(in: .whitespaces)
                    continue
                }
                if trimmed.lowercased().hasPrefix("triggers:") {
                    let raw = trimmed.dropFirst("triggers:".count)
                    triggers = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    continue
                }
                inBody = true   // first non-header line starts the body
            }
            instructionLines.append(line)
        }

        guard let name, !name.isEmpty else { return nil }
        let instructions = instructionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instructions.isEmpty else { return nil }
        // Legacy files have no Description: line — AgentSkill.init derives one
        // from the body's first line so every skill is index-visible.
        return AgentSkill(name: name, description: description,
                          triggerKeywords: triggers, instructions: instructions)
    }

    static func slugify(_ s: String) -> String {
        let mapped = s.lowercased().map { ($0.isLetter || $0.isNumber) ? $0 : "-" }
        let collapsed = String(mapped).replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "skill" : trimmed
    }
}
