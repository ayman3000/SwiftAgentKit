//
//  MemoryInbox.swift
//  SwiftAgentKit
//
//  During a run the model only notes things. Notes wait here until the app
//  files them after the run (deciding user / project / general, merging with
//  what is known, dropping what is not worth keeping). In memory only: notes
//  lost to a crash are acceptable.
//

import Foundation

public struct MemoryNote: Sendable, Codable, Equatable, Identifiable {
    /// The model's optional hint; the filer decides.
    public enum About: String, Sendable, Codable, CaseIterable {
        case me, project, general
    }

    public let id: UUID
    public var text: String
    public var about: About?
    /// The project the conversation was in when the note was made.
    public var project: String?
    public var createdAt: Date
    /// Filing attempts that did not cover this note.
    public var attempts: Int

    public init(id: UUID = UUID(), text: String, about: About? = nil, project: String? = nil,
                createdAt: Date = Date(), attempts: Int = 0) {
        self.id = id
        self.text = text
        self.about = about
        self.project = project
        self.createdAt = createdAt
        self.attempts = attempts
    }
}

public actor MemoryInbox {
    /// Most notes kept waiting; the oldest go first.
    public static let capacity = 20
    /// A note not filed after this many attempts is given up.
    public static let maxAttempts = 3

    private var items: [MemoryNote] = []

    public init() {}

    public var notes: [MemoryNote] { items }
    public var count: Int { items.count }

    public func add(_ note: MemoryNote) {
        items.append(note)
        trim()
    }

    /// Take every waiting note.
    public func drain() -> [MemoryNote] {
        let taken = items
        items.removeAll()
        return taken
    }

    /// Return notes a filing attempt did not cover, so the next run retries them.
    public func putBack(_ failed: [MemoryNote]) {
        let retried = failed
            .map { note -> MemoryNote in var n = note; n.attempts += 1; return n }
            .filter { $0.attempts < Self.maxAttempts }
        items = (retried + items).sorted { $0.createdAt < $1.createdAt }
        trim()
    }

    private func trim() {
        if items.count > Self.capacity { items.removeFirst(items.count - Self.capacity) }
    }
}
