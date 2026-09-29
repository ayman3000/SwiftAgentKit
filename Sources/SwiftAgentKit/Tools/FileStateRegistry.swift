//
//  FileStateRegistry.swift
//  SwiftAgentKit
//
//  Which version of each file every agent last saw, so a whole-file write
//  can't silently throw away a change it never saw — another sub-agent's, the
//  parent's, or the user's (parallel sub-agents, 2026-09-29).
//

import Foundation

/// Per-agent memory of files as that agent last read or wrote them.
///
/// `Agent` runs its loop under `currentAgent`, so the file tools know who is
/// calling; outside an agent run (`currentAgent == nil`) nothing is recorded
/// or guarded. A file is identified by its modification date and size — an
/// atomic write always gives it a new date.
public final class FileStateRegistry: @unchecked Sendable {

    public static let shared = FileStateRegistry()

    /// The agent whose loop is running. Set by `Agent`; a sub-agent's run
    /// sets its own, so parent and children are told apart.
    @TaskLocal public static var currentAgent: UUID?

    struct Stamp: Equatable {
        let modified: Date
        let size: Int
    }

    private let lock = NSLock()
    private var seen: [UUID: [String: Stamp]] = [:]

    init() {}

    /// The calling agent has just read or written `path`: this is now the
    /// version it knows.
    public func noteSeen(path: String) {
        guard let agent = Self.currentAgent else { return }
        let key = Self.key(path)
        let stamp = Self.stamp(of: key)
        lock.withLock {
            if let stamp { seen[agent, default: [:]][key] = stamp }
            else { seen[agent]?[key] = nil }
        }
    }

    /// Why the calling agent must not overwrite `path`, or `nil` when it may:
    /// it never read the file, the file is gone, or it is unchanged since.
    public func staleReason(path: String) -> String? {
        guard let agent = Self.currentAgent else { return nil }
        let key = Self.key(path)
        guard let known = lock.withLock({ seen[agent]?[key] }),
              let now = Self.stamp(of: key), now != known
        else { return nil }
        return "the file changed since you last read it (another agent, a command, or the user changed it)"
    }

    /// Drop everything an agent saw — it is gone.
    public func forget(agent: UUID) {
        _ = lock.withLock { seen.removeValue(forKey: agent) }
    }

    private static func key(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func stamp(of path: String) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? Int
        else { return nil }
        return Stamp(modified: modified, size: size)
    }
}
