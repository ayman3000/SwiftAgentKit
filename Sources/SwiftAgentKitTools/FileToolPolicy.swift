//
//  FileToolPolicy.swift
//  SwiftAgentKitTools
//
//  Opt-in allowed-roots boundary for the filesystem tools. Without a policy the
//  tools remain unrestricted (backward compatible); with one, every path is
//  canonicalized — tilde expanded, `..` collapsed, symlinks resolved — BEFORE
//  the containment check, so `workspace/../secret` or a symlink pointing out of
//  the workspace cannot escape.
//

import Foundation

/// Restricts filesystem tools to a set of allowed root directories.
///
/// ```swift
/// let policy = FileToolPolicy(allowedRoots: [workspaceURL])
/// agent.register(FileReadTool(policy: policy))
/// agent.register(FileWriteTool(policy: policy))
/// ```
public struct FileToolPolicy: Sendable {

    /// Canonicalized root paths. A path is allowed when it equals a root or is
    /// contained inside one.
    public let allowedRoots: [String]

    /// Where a relative path is resolved: the project, not the app's own
    /// working directory (which refused `naseem/rules.md` as "outside the
    /// allowed workspace roots", xontel review 2026-09-28). Defaults to the
    /// first allowed root.
    public let baseDirectory: String?

    public init(allowedRoots: [URL], baseDirectory: URL? = nil) {
        self.allowedRoots = allowedRoots.map { Self.canonicalize($0.path) }
        self.baseDirectory = (baseDirectory ?? allowedRoots.first).map { Self.canonicalize($0.path) }
    }

    /// `~` expanded; a relative path joined to `baseDirectory`.
    public func resolve(_ path: String) -> String {
        let expanded = expandPath(path)
        guard !expanded.hasPrefix("/"), let base = baseDirectory else { return expanded }
        return URL(fileURLWithPath: base).appendingPathComponent(expanded).standardizedFileURL.path
    }

    /// Expand `~`, collapse `.`/`..`, and resolve symlinks. For paths that don't
    /// fully exist yet (a file about to be created), the existing prefix is
    /// resolved and the trailing components pass through unchanged.
    static func canonicalize(_ path: String) -> String {
        URL(fileURLWithPath: expandPath(path))
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    /// Returns a reason the path is refused, or `nil` when it is inside a root.
    public func blockReason(for path: String) -> String? {
        let canonical = Self.canonicalize(path)
        for root in allowedRoots {
            if canonical == root { return nil }
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if canonical.hasPrefix(prefix) { return nil }
        }
        return "the path is outside the allowed workspace roots"
    }
}
