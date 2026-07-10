//
//  AgentGoal.swift
//  SwiftAgentKit
//
//  High-level goal abstraction for agents — generalized from production patterns.
//
//  A goal wraps a user query, an optional execution plan, completion criteria,
//  and a result summary. Goals can be persisted across app launches so
//  long-running work survives restarts.
//

import Foundation

/// Status of an agent goal.
///
public enum AgentGoalStatus: String, Sendable, Codable, Equatable, CaseIterable {
    case pending
    case inProgress
    case completed
    case failed
    case abandoned
}

/// A high-level objective the agent is pursuing.
///
/// A goal is more than a plan: it is the user's original query, the generated
/// plan (if any), status tracking, and a final summary. Goals are useful for
/// exposing progress in a UI, resuming work after a restart, or summarizing
/// what the agent accomplished.
///
public struct AgentGoal: Sendable, Identifiable, Codable, Equatable {

    public let id: String
    public var query: String
    public var status: AgentGoalStatus
    public var plan: AgentPlan?
    public var summary: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        query: String,
        status: AgentGoalStatus = .pending,
        plan: AgentPlan? = nil,
        summary: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.query = query
        self.status = status
        self.plan = plan
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Mark the goal as in-progress.
    public mutating func start() {
        status = .inProgress
        updatedAt = Date()
    }

    /// Mark the goal as completed with an optional summary.
    public mutating func complete(summary: String? = nil) {
        status = .completed
        self.summary = summary
        updatedAt = Date()
    }

    /// Mark the goal as failed with an optional summary.
    public mutating func fail(summary: String? = nil) {
        status = .failed
        self.summary = summary
        updatedAt = Date()
    }

    /// Mark the goal as abandoned.
    public mutating func abandon() {
        status = .abandoned
        updatedAt = Date()
    }

    /// Whether there is remaining work to do.
    public var isActive: Bool {
        status == .pending || status == .inProgress
    }

    /// Current progress as a fraction (0.0 to 1.0). Returns 1.0 for completed
    /// or abandoned goals; 0.0 for pending goals with no plan.
    public var progress: Double {
        switch status {
        case .completed, .abandoned:
            return 1.0
        case .failed:
            return 0.0
        case .pending:
            return 0.0
        case .inProgress:
            guard let plan = plan else { return 0.0 }
            return plan.progress
        }
    }
}

// MARK: - Goal Store

/// A store that persists agent goals.
///
/// Implement this for custom storage. The default `FileAgentGoalStore` saves
/// each goal as JSON in a directory chosen by the app.
///
public protocol AgentGoalStore: Sendable {

    /// Save or update a goal.
    func save(_ goal: AgentGoal) async throws

    /// Load a goal by ID.
    func load(id: String) async throws -> AgentGoal?

    /// Load all goals.
    func loadAll() async throws -> [AgentGoal]

    /// Delete a goal.
    func delete(id: String) async throws
}

// MARK: - File-based Goal Store

public final class FileAgentGoalStore: AgentGoalStore, @unchecked Sendable {

    public let directory: URL
    private let fileManager = FileManager.default

    public init(directory: URL) {
        self.directory = directory
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public convenience init(directoryPath: String) {
        self.init(directory: URL(fileURLWithPath: directoryPath))
    }

    /// Convenience: create a store under the user's home directory.
    ///
    /// - Parameter name: The app-specific folder name. `name: "kommanda"` produces `~/.kommanda/goals`.
    public static func defaultStore(named name: String) -> FileAgentGoalStore {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return FileAgentGoalStore(directory: home.appendingPathComponent(".\(name)/goals"))
    }

    private func url(for id: String) -> URL {
        directory.appendingPathComponent("\(sanitize(id)).json")
    }

    public func save(_ goal: AgentGoal) async throws {
        let data = try JSONEncoder().encode(goal)
        try data.write(to: url(for: goal.id))
    }

    public func load(id: String) async throws -> AgentGoal? {
        let url = url(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AgentGoal.self, from: data)
    }

    public func loadAll() async throws -> [AgentGoal] {
        let contents = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        var goals: [AgentGoal] = []
        for file in contents.filter({ $0.hasSuffix(".json") }).sorted() {
            let id = String(file.dropLast(5))
            if let goal = try await load(id: id) {
                goals.append(goal)
            }
        }
        return goals
    }

    public func delete(id: String) async throws {
        let url = url(for: id)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func sanitize(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_")
          .replacingOccurrences(of: ":", with: "-")
    }
}
