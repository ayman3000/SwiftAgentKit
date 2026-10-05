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
        /// `slug` names the fact's file when it is not the title's own slug
        /// (a hand-made `notes.md` headed `# My Notes`); nil means
        /// `slugify(title)`, so the common case compares equal without it.
        case fact(title: String, project: String?, slug: String? = nil)
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
    /// The file's name without `.md`. Usually the title's slug, but a file
    /// made by hand can be named anything; pass this to `deleteFact(slug:)`,
    /// `moveFact(slug:)` to reach exactly this file.
    public let slug: String
    public var id: String { (project ?? "") + "\u{1F}" + slug }

    public init(title: String, body: String, project: String?, slug: String? = nil) {
        self.title = title
        self.body = body
        self.project = project
        self.slug = slug ?? FileAgentMemoryStore.slugify(title)
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
///
/// ```swift
/// let change = try await MemoryFileWork.run { try store.setUserKey("Name", value: "Ayman") }
/// ```
public enum MemoryFileWork {
    /// Run `body` on a global utility queue and resume with its result.
    public static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}
