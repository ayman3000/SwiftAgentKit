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

    public init(
        id: String = UUID().uuidString,
        kind: AgentMemoryKind,
        title: String,
        content: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.content = content
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
}

// MARK: - File-based Memory Store

/// A markdown-backed memory store that lives in a configurable directory.
///
/// Layout:
///
///     <directory>/
///       AGENT.md     — identity, principles
///       USER.md      — facts about the user
///       memory/      — discrete fact files
///         <slug>.md
///       MEMORY.md    — index of memory/*.md files
///
/// Apps decide the directory. A file-manager app might use `~/.kommanda`,
/// a different app might use `~/.myagent`.
///
public final class FileAgentMemoryStore: AgentMemoryStore, @unchecked Sendable {

    public let directory: URL
    private let fileManager = FileManager.default

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
            let slug = Self.slugify(entry.title)
            let fileURL = memoryDirectory.appendingPathComponent("\(slug).md")
            let body = "# \(entry.title)\n\n\(entry.content)\n"
            try body.write(to: fileURL, atomically: true, encoding: .utf8)
            addIndexLine(title: entry.title, slug: slug)
        }
    }

    public func delete(id: String) async throws {
        // File store IDs are derived from titles; delete by slug for facts.
        let slug = Self.slugify(id)
        let fileURL = memoryDirectory.appendingPathComponent("\(slug).md")
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        removeIndexLine(slug: slug)
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

        let memoryFiles = (try? fileManager.contentsOfDirectory(atPath: memoryDirectory.path)) ?? []
        for file in memoryFiles.filter({ $0.hasSuffix(".md") }).sorted() {
            let fileURL = memoryDirectory.appendingPathComponent(file)
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let title = Self.titleFromMarkdown(content) ?? String(file.dropLast(3))
            entries.append(AgentMemoryEntry(kind: .fact, title: title, content: content))
        }

        return entries
    }

    public func load(kind: AgentMemoryKind) async throws -> [AgentMemoryEntry] {
        try await loadAll().filter { $0.kind == kind }
    }

    public func loadContextBlock() async -> String {
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

        return """
        === MEMORY (persistent — you already know this about the user; don't ask them to re-introduce themselves) ===
        \(agent)

        \(user)

        Memory index — read the referenced file with your file tools when a line is relevant:
        \(index)
        \(coldStart)
        === END MEMORY ===


        """
    }

    // MARK: - Index helpers

    private func addIndexLine(title: String, slug: String) {
        var text = (try? String(contentsOf: indexURL, encoding: .utf8)) ?? Self.defaultIndex
        let newLine = "- [\(title)](memory/\(slug).md)"
        var lines = text.components(separatedBy: "\n").filter { !$0.contains("(memory/\(slug).md)") }
        lines.append(newLine)
        text = lines.joined(separator: "\n")
        try? text.write(to: indexURL, atomically: true, encoding: .utf8)
    }

    private func removeIndexLine(slug: String) {
        guard var text = try? String(contentsOf: indexURL, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\n").filter { !$0.contains("(memory/\(slug).md)") }
        text = lines.joined(separator: "\n")
        try? text.write(to: indexURL, atomically: true, encoding: .utf8)
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
