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

    public init(allowedRoots: [URL]) {
        self.allowedRoots = allowedRoots.map { Self.canonicalize($0.path) }
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
