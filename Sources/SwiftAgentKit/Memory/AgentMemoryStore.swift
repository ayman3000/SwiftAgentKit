//
//  AgentMemoryStore.swift
//  SwiftAgentKit
//
//  Persistent memory abstraction for agents — generalized from production patterns.
//
//  Provides a configurable, file-backed memory store that an app can point at
//  any directory (e.g. ~/.kommanda). The kit never hardcodes a folder name.
//

import Foundation

/// A durable fact stored by an agent.
///
/// `AgentMemoryEntry` is the unit of memory. Entries are persisted by a
/// `AgentMemoryStore` implementation and injected into future system prompts.
///
public struct AgentMemoryEntry: Sendable, Identifiable, Codable, Equatable {

    public let id: String
    public var kind: AgentMemoryKind
    public var title: String
    public var content: String
    public let createdAt: Date
    public var updatedAt: Date

    /// The project this memory belongs to, or nil for a memory that is true
    /// everywhere.
    ///
    /// A fact like "Phase 1 starts with the voice agent" is about one piece of
    /// work, and presenting it as a standing truth in an unrelated
    /// conversation is how an agent ends up pursuing the wrong mission. Facts
    /// learned inside a project are filed under it and loaded only when it is
    /// open. Preferences and facts about the user stay global — those are
    /// about how someone works, not about one codebase.
    public var project: String?

    public init(
        id: String = UUID().uuidString,
        kind: AgentMemoryKind,
        title: String,
        content: String,
        project: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.content = content
        self.project = project
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Category of a memory entry.
///
/// - `agent`: the agent's own identity, principles, and behavior rules.
/// - `user`: durable facts about the user (name, role, preferences).
/// - `fact`: discrete learned facts about the world, projects, conventions, etc.
///
public enum AgentMemoryKind: String, Sendable, Codable, Equatable, CaseIterable {
    case agent
    case user
    case fact
}

/// A store that persists agent memory across sessions.
///
/// Implement this to provide custom storage (Core Data, keychain, cloud, etc.).
/// The default `FileAgentMemoryStore` uses plain markdown files in a directory.
///
public protocol AgentMemoryStore: Sendable {

    /// Persist a memory entry.
    func save(_ entry: AgentMemoryEntry) async throws

    /// Delete a memory entry by ID.
    func delete(id: String) async throws

    /// Load all memory entries.
    func loadAll() async throws -> [AgentMemoryEntry]

    /// Load entries filtered by kind.
    func load(kind: AgentMemoryKind) async throws -> [AgentMemoryEntry]

    /// Build a context block suitable for injection into a system prompt.
    func loadContextBlock() async -> String

    /// Build a context block for a conversation working inside `project`.
    ///
    /// Global memory always appears; the named project's memory is added to
    /// it. Other projects' memory is left out — that is the whole point.
    func loadContextBlock(project: String?) async -> String
}

public extension AgentMemoryStore {
    /// Stores that do not scope by project simply ignore it.
    func loadContextBlock(project: String?) async -> String {
        await loadContextBlock()
    }
}

// MARK: - File-based Memory Store

/// A markdown-backed memory store that lives in a configurable directory.
///
/// Layout:
///
///     <directory>/
///       AGENT.md     — identity, principles
///       USER.md      — facts about the user
///       memory/      — discrete fact files that are true everywhere
///         <slug>.md
///         projects/<project-slug>/
///           <slug>.md      — facts that belong to one project
///           MEMORY.md      — that project's own index
///       MEMORY.md    — index of the global memory/*.md files
///
/// Apps decide the directory. A file-manager app might use `~/.kommanda`,
/// a different app might use `~/.myagent`.
///
public final class FileAgentMemoryStore: AgentMemoryStore, @unchecked Sendable {

    public let directory: URL
    private let fileManager = FileManager.default
    /// Serializes mutating operations so concurrent `save`/`delete` calls don't
    /// race on read-modify-write of USER.md and the MEMORY.md index (which would
    /// lose writes or corrupt the index). Safe to hold across these methods
    /// because their bodies perform only synchronous file I/O (no `await`).
    private let lock = NSLock()

    /// Create a memory store rooted at the given directory.
    public init(directory: URL) {
        self.directory = directory
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Convenience: create from a filesystem path string.
    public convenience init(directoryPath: String) {
        self.init(directory: URL(fileURLWithPath: directoryPath))
    }

    /// Convenience: create a store under the user's home directory.
    ///
    /// - Parameter name: The app-specific folder name. For example,
    ///   `name: "kommanda"` produces `~/.kommanda`.
    public static func defaultStore(named name: String) -> FileAgentMemoryStore {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return FileAgentMemoryStore(directory: home.appendingPathComponent(".\(name)"))
    }

    private var memoryDirectory: URL { directory.appendingPathComponent("memory") }
    private var agentURL: URL { directory.appendingPathComponent("AGENT.md") }
    private var userURL: URL { directory.appendingPathComponent("USER.md") }
    private var indexURL: URL { directory.appendingPathComponent("MEMORY.md") }

    private var projectsDirectory: URL { memoryDirectory.appendingPathComponent("projects") }

    private func directory(forProject project: String) -> URL {
        projectsDirectory.appendingPathComponent(Self.slugify(project))
    }

    private func indexURL(forProject project: String?) -> URL {
        guard let project else { return indexURL }
        return directory(forProject: project).appendingPathComponent("MEMORY.md")
    }

    private func factURL(slug: String, project: String?) -> URL {
        guard let project else { return memoryDirectory.appendingPathComponent("\(slug).md") }
        return directory(forProject: project).appendingPathComponent("\(slug).md")
    }

    /// Every project that has filed at least one memory, by the name the
    /// caller used.
    ///
    /// Folders are named by slug so they are safe on disk, but a caller that
    /// saved under "XonTel" must get "XonTel" back, not "xontel" — otherwise
    /// the name that reaches the model and the inspector is a mangled one. The
    /// display name is kept as the H1 of that project's index.
    public var knownProjects: [String] {
        let dirs = (try? fileManager.contentsOfDirectory(atPath: projectsDirectory.path)) ?? []
        return dirs.filter { !$0.hasPrefix(".") }.map { displayName(forSlug: $0) }.sorted()
    }

    private func displayName(forSlug slug: String) -> String {
        let url = projectsDirectory.appendingPathComponent(slug).appendingPathComponent("MEMORY.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let first = text.components(separatedBy: "\n").first(where: { $0.hasPrefix("# ") })
        else { return slug }
        return String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    private func ensureMemoryDirectory() {
        try? fileManager.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Seeding

    /// Ensure default files exist. Idempotent.
    public func seedIfNeeded() {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)

        if !fileManager.fileExists(atPath: agentURL.path) {
            try? Self.defaultAgentSoul.write(to: agentURL, atomically: true, encoding: .utf8)
        }
        if !fileManager.fileExists(atPath: userURL.path) {
            try? Self.defaultUserSoul.write(to: userURL, atomically: true, encoding: .utf8)
        }
        if !fileManager.fileExists(atPath: indexURL.path) {
            try? Self.defaultIndex.write(to: indexURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - AgentMemoryStore

    public func save(_ entry: AgentMemoryEntry) async throws {
        // Scoped lock (no `await` inside) serializes the read-modify-write of
        // USER.md and the MEMORY.md index against concurrent save/delete calls.
        try lock.withLock {
            seedIfNeeded()

            switch entry.kind {
            case .agent:
                let body = "# \(entry.title)\n\n\(entry.content)\n"
                try body.write(to: agentURL, atomically: true, encoding: .utf8)

            case .user:
                let line = "- **\(entry.title):** \(entry.content)\n"
                let existing = (try? String(contentsOf: userURL, encoding: .utf8)) ?? Self.defaultUserSoul
                try (existing + line).write(to: userURL, atomically: true, encoding: .utf8)

            case .fact:
                // A project fact lands in that project's folder and its own
                // index, so opening a different project never surfaces it.
                let slug = Self.slugify(entry.title)
                let fileURL = factURL(slug: slug, project: entry.project)
                try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
                let body = "# \(entry.title)\n\n\(entry.content)\n"
                try body.write(to: fileURL, atomically: true, encoding: .utf8)
                addIndexLine(title: entry.title, slug: slug, project: entry.project)
            }
        }
    }

    public func delete(id: String) async throws {
        try lock.withLock {
            // File store IDs are derived from titles; delete by slug for facts.
            // NOTE: fact files are named by *title* slug, so callers must pass the
            // entry's title here (not its UUID `id`) for the delete to match.
            let slug = Self.slugify(id)
            // A fact may be global or filed under a project; the caller passes
            // only a title, so clear it wherever it sits.
            for project in [nil] + knownProjects.map(Optional.init) {
                let fileURL = factURL(slug: slug, project: project)
                if fileManager.fileExists(atPath: fileURL.path) {
                    try fileManager.removeItem(at: fileURL)
                }
                removeIndexLine(slug: slug, project: project)
            }
        }
    }

    public func loadAll() async throws -> [AgentMemoryEntry] {
        seedIfNeeded()
        var entries: [AgentMemoryEntry] = []

        if let agent = try? String(contentsOf: agentURL, encoding: .utf8), !agent.isEmpty {
            entries.append(AgentMemoryEntry(kind: .agent, title: "Agent Soul", content: agent))
        }

        if let user = try? String(contentsOf: userURL, encoding: .utf8), !user.isEmpty {
            entries.append(AgentMemoryEntry(kind: .user, title: "User", content: user))
        }

        entries += facts(inDirectory: memoryDirectory, project: nil)
        for project in knownProjects {
            entries += facts(inDirectory: directory(forProject: project), project: project)
        }

        return entries
    }

    /// Read the fact files directly inside one folder. A project's own
    /// MEMORY.md index is not a fact and is skipped.
    private func facts(inDirectory url: URL, project: String?) -> [AgentMemoryEntry] {
        let files = (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []
        return files.filter { $0.hasSuffix(".md") && $0 != "MEMORY.md" }.sorted().compactMap { file in
            guard let content = try? String(contentsOf: url.appendingPathComponent(file), encoding: .utf8)
            else { return nil }
            return AgentMemoryEntry(kind: .fact,
                                    title: Self.titleFromMarkdown(content) ?? String(file.dropLast(3)),
                                    content: content,
                                    project: project)
        }
    }

    public func load(kind: AgentMemoryKind) async throws -> [AgentMemoryEntry] {
        try await loadAll().filter { $0.kind == kind }
    }

    public func loadContextBlock() async -> String {
        await loadContextBlock(project: nil)
    }

    public func loadContextBlock(project: String?) async -> String {
        seedIfNeeded()
        let agent = (try? String(contentsOf: agentURL, encoding: .utf8)) ?? ""
        let user = (try? String(contentsOf: userURL, encoding: .utf8)) ?? ""
        let index = (try? String(contentsOf: indexURL, encoding: .utf8)) ?? ""

        guard !agent.isEmpty || !user.isEmpty || !index.isEmpty else { return "" }

        let coldStart = isUserKnown(user: user, index: index) ? "" : """

        NOTE — you barely know this user yet (memory is nearly empty). Early in the
        conversation, warmly offer to get to know them — ideally by exploring a
        folder they point you to ("want me to look at your projects and figure out
        who you are?"), or they can just tell you. Then use the remember tool to save
        what matters. Offer ONCE; if they decline, drop it and don't ask again.
        """

        // Only THIS project's memory joins the global set. Another project's
        // decisions are not background truth here, and an agent handed them
        // will act on them.
        var projectSection = ""
        if let project,
           let projectIndex = try? String(contentsOf: indexURL(forProject: project), encoding: .utf8),
           !projectIndex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            projectSection = """


            Memory filed under the project you are working in (\(project)) — paths are relative to the memory root:
            \(projectIndex)
            """
        }

        return """
        === MEMORY (persistent — you already know this about the user; don't ask them to re-introduce themselves) ===
        \(agent)

        \(user)

        Memory index — read the referenced file with your file tools when a line is relevant:
        \(index)\(projectSection)
        \(coldStart)
        === END MEMORY ===


        """
    }

    // MARK: - Index helpers

    /// The link a fact's index line carries. Relative to the store root for
    /// global facts, and to the project folder for project facts, so either
    /// index can be handed to a file tool as-is.
    private static func link(slug: String, project: String?) -> String {
        guard let project else { return "memory/\(slug).md" }
        return "memory/projects/\(slugify(project))/\(slug).md"
    }

    private func addIndexLine(title: String, slug: String, project: String? = nil) {
        let url = indexURL(forProject: project)
        let link = Self.link(slug: slug, project: project)
        // The H1 carries the project's display name — see `knownProjects`.
        let fallback = project == nil ? Self.defaultIndex : "# \(project!)\n"
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? fallback
        var lines = text.components(separatedBy: "\n").filter { !$0.contains("(\(link))") }
        lines.append("- [\(title)](\(link))")
        text = lines.joined(separator: "\n")
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func removeIndexLine(slug: String, project: String? = nil) {
        let url = indexURL(forProject: project)
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let link = Self.link(slug: slug, project: project)
        text = text.components(separatedBy: "\n").filter { !$0.contains("(\(link))") }
            .joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func isUserKnown(user: String, index: String) -> Bool {
        let userFactLines = user
            .components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }
            .count
        let hasLearnedFacts = index.contains("(memory/")
        return hasLearnedFacts || userFactLines >= 2
    }

    // MARK: - Helpers

    private static func titleFromMarkdown(_ markdown: String) -> String? {
        guard let line = markdown.components(separatedBy: .newlines).first else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("# ") { return String(trimmed.dropFirst(2)) }
        if trimmed.hasPrefix("## ") { return String(trimmed.dropFirst(3)) }
        return nil
    }

    static func slugify(_ s: String) -> String {
        let lowered = s.lowercased()
        let allowed = lowered.map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        let collapsed = String(allowed).replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-")).isEmpty
            ? "note-\(Int(Date().timeIntervalSince1970))"
            : collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - Default seed content

    private static let defaultAgentSoul = """
    # Agent Soul

    You are a helpful, capable agent. Use your tools proactively. Remember what
    matters about the user and their projects. Act with care on their data.
    """

    private static let defaultUserSoul = """
    # User

    What the agent knows about you. Edit freely.

    """

    private static let defaultIndex = """
    # Memory Index

    One line per saved memory. The agent reads the linked file when relevant.

    """
}
