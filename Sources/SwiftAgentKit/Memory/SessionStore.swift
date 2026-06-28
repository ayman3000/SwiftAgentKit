//
//  SessionStore.swift
//  SwiftAgentKit
//
//  Recommendation 3: Session persistence protocol + file-based implementation.
//  Conversation history is saved to disk and can be restored when the app restarts.
//

import Foundation

/// A protocol for persisting and restoring conversation sessions.
///
/// Implement this to save/load agent conversations. The default
/// `FileSessionStore` saves to JSON files in a directory.
///
public protocol SessionStore: Sendable {

    /// Save a conversation under the given session ID.
    func save(sessionId: String, messages: [AgentMessage]) async throws

    /// Load a conversation by session ID. Returns nil if not found.
    func load(sessionId: String) async throws -> [AgentMessage]?

    /// Delete a session.
    func delete(sessionId: String) async throws

    /// List all saved session IDs.
    func listSessions() async throws -> [String]
}

// MARK: - File-based Session Store

/// A session store that saves conversations as JSON files in a directory.
///
/// Each session is stored as `<sessionId>.json` containing the message array.
/// This is simple, human-readable, and works on all Apple platforms without
/// any external dependencies.
///
public final class FileSessionStore: SessionStore, @unchecked Sendable {

    public let directory: URL
    private let fileManager = FileManager.default

    public init(directory: URL) {
        self.directory = directory
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public convenience init(directoryPath: String) {
        self.init(directory: URL(fileURLWithPath: directoryPath))
    }

    public func save(sessionId: String, messages: [AgentMessage]) async throws {
        let url = directory.appendingPathComponent("\(sanitize(sessionId)).json")
        let data = try JSONEncoder().encode(messages)
        try data.write(to: url)
    }

    public func load(sessionId: String) async throws -> [AgentMessage]? {
        let url = directory.appendingPathComponent("\(sanitize(sessionId)).json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([AgentMessage].self, from: data)
    }

    public func delete(sessionId: String) async throws {
        let url = directory.appendingPathComponent("\(sanitize(sessionId)).json")
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    public func listSessions() async throws -> [String] {
        let contents = try fileManager.contentsOfDirectory(atPath: directory.path)
        return contents
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .sorted()
    }

    private func sanitize(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_")
          .replacingOccurrences(of: ":", with: "-")
    }
}

// MARK: - Agent Session Management Extension

public extension Agent {

    /// Save the current conversation to a session store.
    func saveSession(store: SessionStore, sessionId: String) async throws {
        try await store.save(sessionId: sessionId, messages: conversation.allMessages())
    }

    /// Load a conversation from a session store and restore it.
    func loadSession(store: SessionStore, sessionId: String) async throws -> Bool {
        guard let saved = try await store.load(sessionId: sessionId) else { return false }
        conversation.clear()
        conversation.append(saved)
        return true
    }

    /// Clear the current conversation and delete the session from the store.
    func clearSession(store: SessionStore, sessionId: String) async throws {
        conversation.clear()
        try await store.delete(sessionId: sessionId)
    }
}