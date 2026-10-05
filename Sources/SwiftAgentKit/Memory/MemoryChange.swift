//
//  MemoryChange.swift
//  SwiftAgentKit
//
//  What one memory write did — the file's text before and after — so an app
//  can show it and undo it exactly. Plus the read-side snapshot types.
//

import Foundation

public struct MemoryChange: Sendable, Codable, Equatable {
    public enum Target: Sendable, Codable, Equatable, Hashable {
        case agentProfile
        case userProfile
        case fact(title: String, project: String?)
    }
    public var target: Target
    /// The file's full text before the write; nil when it did not exist.
    public var before: String?
    /// The file's full text after the write; nil when the write removed it.
    public var after: String?

    public init(target: Target, before: String?, after: String?) {
        self.target = target
        self.before = before
        self.after = after
    }
}

/// One fact with its heading stripped.
public struct MemoryFact: Sendable, Equatable, Hashable, Identifiable {
    public var title: String
    public var body: String
    /// nil = true everywhere.
    public var project: String?
    public var id: String { (project ?? "") + "\u{1F}" + title.lowercased() }

    public init(title: String, body: String, project: String?) {
        self.title = title
        self.body = body
        self.project = project
    }
}

public struct MemorySnapshot: Sendable, Equatable {
    public var agentProfile: String
    public var userProfile: String
    public var facts: [MemoryFact]

    public init(agentProfile: String, userProfile: String, facts: [MemoryFact]) {
        self.agentProfile = agentProfile
        self.userProfile = userProfile
        self.facts = facts
    }
}

public enum MemoryStoreError: Error, Equatable {
    case factNotFound(String)
}

/// Memory file reads and writes are synchronous. Run them on a GCD thread,
/// never on Swift's cooperative pool.
enum MemoryFileWork {
    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}
