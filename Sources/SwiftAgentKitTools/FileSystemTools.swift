//
//  FileSystemTools.swift
//  SwiftAgentKitTools
//
//  Generic, Foundation-only filesystem tools. Reads are unconfirmed; writes are
//  gated (`requiresConfirmation`) so the app's `onToolConfirmation` handler must
//  approve them. Cross-platform (any Apple platform + Linux).
//

import Foundation
import SwiftAgentKit

/// Read a UTF-8 text file. Unconfirmed (read-only). Pages large files.
public struct FileReadTool: AgentTool {
    public let name = "read_file"
    public var isReadOnly: Bool { true }
    public let description = """
    Read a UTF-8 text file and return its contents. Files up to ~40,000 characters \
    come back whole — read them in ONE call. Use `offset` and `limit` only to page \
    through genuinely large files, in big slices: every call re-sends the whole \
    conversation, so many small reads cost far more than one large one.
    """
    public let parameters = ToolParameters(
        properties: [
            "path": ToolParameterProperty(type: "string", description: "File path (a leading ~ is expanded)."),
            "offset": ToolParameterProperty(type: "integer", description: "Start character offset (default 0)."),
            "limit": ToolParameterProperty(type: "integer", description: "Max characters to read (default 40000). Small values are widened — paging in tiny slices is the most expensive way to read a file."),
        ],
        required: ["path"]
    )

    public var inputExamples: [String] { [
        #"""
        {"path": "~/proj/app/Package.swift"}
        """#,
        #"""
        {"path": "~/proj/app/logs/build.log", "offset": 200000, "limit": 20000}
        """#
    ] }

    let policy: FileToolPolicy?

    public init(policy: FileToolPolicy? = nil) { self.policy = policy }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let raw = (parameters["path"] as? String), !raw.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "read_file requires a `path`.")
        }
        let path = policy?.resolve(raw) ?? expandPath(raw)
        if let policy, let reason = policy.blockReason(for: path) {
            return .error(toolCallId: "", toolName: name, message: "Refusing to read \(raw): \(reason).")
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            return .error(toolCallId: "", toolName: name, message: "Cannot read file: \(raw)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .error(toolCallId: "", toolName: name, message: "Not a UTF-8 text file: \(raw)")
        }
        let chars = Array(text)
        // `limit` is a hint: ReadSlice refuses to serve a slice so small that
        // paging costs more in round trips than the content is worth.
        let slice = ReadSlice(totalChars: chars.count,
                              offset: intValue(parameters["offset"]),
                              limit: intValue(parameters["limit"]))
        let body = String(chars[slice.start..<slice.end])
        FileStateRegistry.shared.noteSeen(path: path)
        ToolTrace.read(tool: name, path: path, offset: slice.start,
                       requested: intValue(parameters["limit"]),
                       served: slice.end - slice.start, total: chars.count,
                       more: slice.end < chars.count)
        return .success(toolCallId: "", toolName: name, result: slice.annotate(body))
    }
}

/// Write (or append) a text file. Confirmation required — it mutates the disk.
public struct FileWriteTool: AgentTool {
    public let name = "write_file"
    public let description = """
    Write UTF-8 text to a file, creating it (and any missing parent folders) if \
    needed. Overwrites by default; set `append: true` to append. Requires approval.
    """
    public let parameters = ToolParameters(
        properties: [
            "path": ToolParameterProperty(type: "string", description: "File path (a leading ~ is expanded)."),
            "content": ToolParameterProperty(type: "string", description: "The text to write."),
            "append": ToolParameterProperty(type: "boolean", description: "Append instead of overwrite (default false)."),
        ],
        required: ["path", "content"]
    )

    public var inputExamples: [String] { [
        #"""
        {"path": "~/proj/app/naseem/report.md", "content": "# Findings\n\n- The retry loop never resets its counter.\n"}
        """#,
        #"""
        {"path": "~/proj/app/naseem/log.txt", "content": "run finished\n", "append": true}
        """#
    ] }

    public var requiresConfirmation: Bool { true }

    let policy: FileToolPolicy?

    /// Which interpreter judges the written file. The host names the one that
    /// will actually run it (Naseem: its own venv); empty means "guess at the
    /// newest copy on this machine".
    let verifier: WriteVerifierConfig

    public init(policy: FileToolPolicy? = nil, verifier: WriteVerifierConfig = .default) {
        self.policy = policy
        self.verifier = verifier
    }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let raw = (parameters["path"] as? String), !raw.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "write_file requires a `path`.")
        }
        guard let content = parameters["content"] as? String else {
            return .error(toolCallId: "", toolName: name, message: "write_file requires `content`.")
        }
        let path = policy?.resolve(raw) ?? expandPath(raw)
        if let policy, let reason = policy.blockReason(for: path) {
            return .error(toolCallId: "", toolName: name, message: "Refusing to write \(raw): \(reason).")
        }
        let url = URL(fileURLWithPath: path)
        let append = boolValue(parameters["append"]) ?? false

        // Appending adds to whatever is there; overwriting a file that changed
        // since this agent last saw it would throw that change away.
        if !append, let stale = FileStateRegistry.shared.staleReason(path: path) {
            return .error(toolCallId: "", toolName: name, message: """
            Not written: \(raw) — \(stale). Read it again, then write a version \
            that keeps those changes (or use edit_file for a targeted change).
            """)
        }

        // TRANSACTION: snapshot the original so a corrupted write can be
        // rolled back — content sometimes arrives damaged in transit (see
        // WriteVerifier). A broken write must never persist.
        let existedBefore = FileManager.default.fileExists(atPath: path)
        let original: Data? = existedBefore ? FileManager.default.contents(atPath: path) : nil

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

            if append, existedBefore {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(content.utf8))
            } else {
                try Data(content.utf8).write(to: url, options: .atomic)
            }
        } catch {
            return .error(toolCallId: "", toolName: name, message: "Write failed: \(error.localizedDescription)")
        }

        // Verify what LANDED (for append: the whole resulting file).
        let landed = (append && existedBefore)
            ? (FileManager.default.contents(atPath: path)
                .flatMap { String(data: $0, encoding: .utf8) } ?? content)
            : content
        if let rejection = await WriteVerifier.rejection(path: path, content: landed, config: verifier) {
            if let original {
                try? original.write(to: url, options: .atomic)      // restore
            } else {
                try? FileManager.default.removeItem(at: url)        // never existed
            }
            return .error(toolCallId: "", toolName: name, message: """
            Write to \(raw) REJECTED — \(rejection.reason).

            \(rejection.guidance)
            """)
        }

        FileStateRegistry.shared.noteSeen(path: path)
        let verb = append ? "Appended" : "Wrote"
        return .success(toolCallId: "", toolName: name, result: "\(verb) \(content.utf8.count) bytes to \(raw).")
    }
}

/// Apply a git-style unified diff to a single existing file. Confirmation
/// required — it mutates the disk. Applies by matching each hunk's context
/// (line numbers are treated as hints), so a diff whose `@@` numbers drifted
/// still applies. Prefer this over rewriting a whole file with `write_file`.
public struct PatchFileTool: AgentTool {
    public let name = "apply_patch"
    public let description = """
    Edit an existing file by applying a unified diff (git / `diff -u` format). \
    Provide the smallest diff that makes the change — one or more `@@` hunks with \
    a few lines of surrounding context; `-` lines are removed, `+` lines added. \
    Line numbers in `@@` headers may be approximate (matched by context, tolerant \
    of whitespace drift). Prefer this over `write_file` for changes to an existing \
    file. Every hunk line starts with its marker, even when the file's own line \
    starts with `-` or `+`: remove the bullet `- item` with `-- item`, keep it as \
    context with ` - item`. For small edits and for markdown lists, `edit_file` is \
    simpler. If a hunk fails, the error includes the file's current lines near the \
    spot — regenerate the diff from those, don't fall back to rewriting the whole \
    file. Requires approval.
    """
    public let parameters = ToolParameters(
        properties: [
            "path": ToolParameterProperty(type: "string", description: "File to patch (a leading ~ is expanded)."),
            "patch": ToolParameterProperty(type: "string", description: "A unified diff (git/diff -u). Only text hunks; no binary/rename."),
        ],
        required: ["path", "patch"]
    )

    public var inputExamples: [String] { [
        #"""
        {"path": "~/proj/app/Sources/Login.swift", "patch": "--- a/Sources/Login.swift\n+++ b/Sources/Login.swift\n@@ -12,7 +12,7 @@ struct Login {\n     func submit() {\n-        guard !email.isEmpty else { return }\n+        guard !email.isEmpty, email.contains(\"@\") else { return }\n         send()\n     }"}
        """#
    ] }

    public var requiresConfirmation: Bool { true }

    let policy: FileToolPolicy?

    /// Which interpreter judges the written file. The host names the one that
    /// will actually run it (Naseem: its own venv); empty means "guess at the
    /// newest copy on this machine".
    let verifier: WriteVerifierConfig

    public init(policy: FileToolPolicy? = nil, verifier: WriteVerifierConfig = .default) {
        self.policy = policy
        self.verifier = verifier
    }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let raw = (parameters["path"] as? String), !raw.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "apply_patch requires a `path`.")
        }
        guard let patch = parameters["patch"] as? String, !patch.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "apply_patch requires a `patch` (a unified diff).")
        }
        let path = policy?.resolve(raw) ?? expandPath(raw)
        if let policy, let reason = policy.blockReason(for: path) {
            return .error(toolCallId: "", toolName: name, message: "Refusing to patch \(raw): \(reason).")
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            return .error(toolCallId: "", toolName: name,
                message: "Cannot read file to patch: \(raw). Use write_file to create a new file.")
        }
        guard let source = String(data: data, encoding: .utf8) else {
            return .error(toolCallId: "", toolName: name, message: "Not a UTF-8 text file: \(raw)")
        }
        guard let hunks = UnifiedDiff.parse(patch) else {
            return .error(toolCallId: "", toolName: name,
                message: "The `patch` isn't a valid unified diff (no @@ hunks found).")
        }

        switch UnifiedDiff.apply(hunks, to: source) {
        case .failure(let err):
            switch err {
            case .hunkNotFound(let index, let preview, let nearby, let diagnosis):
                let why = diagnosis.map { " \($0)" } ?? " The surrounding lines weren't found: \"\(preview)\"."
                return .error(toolCallId: "", toolName: name, message: """
                Hunk \(index + 1) didn't match \(raw).\(why) \
                Nothing was changed. The file's CURRENT content near that spot is:

                \(nearby)

                Regenerate the diff against these actual lines (do not rewrite the whole file).
                """)
            case .cannotAnchor(let index):
                return .error(toolCallId: "", toolName: name, message: """
                Hunk \(index + 1) is an insertion whose line number is past the end of \(raw). \
                Add a line of context so it can be anchored. Nothing was changed.
                """)
            }
        case .success(let patched):
            // TRANSACTION: verify the patched result before it can persist —
            // a hunk that applies cleanly can still leave broken syntax when
            // the patch content itself was corrupted in transit.
            if let rejection = await WriteVerifier.rejection(path: path, content: patched, config: verifier) {
                return .error(toolCallId: "", toolName: name, message: """
                Patch to \(raw) REJECTED — applying it would leave the file broken: \(rejection.reason).

                \(rejection.guidance)
                """)
            }
            do {
                try Data(patched.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                return .error(toolCallId: "", toolName: name, message: "Write failed: \(error.localizedDescription)")
            }
            FileStateRegistry.shared.noteSeen(path: path)
            let added = hunks.reduce(0) { $0 + $1.lines.filter { if case .add = $0 { return true }; return false }.count }
            let removed = hunks.reduce(0) { $0 + $1.lines.filter { if case .remove = $0 { return true }; return false }.count }
            return .success(toolCallId: "", toolName: name,
                result: "Applied \(hunks.count) hunk\(hunks.count == 1 ? "" : "s") (+\(added)/-\(removed)) to \(raw).")
        }
    }
}

/// Replace exact text in a file — no diff markers. Confirmation required.
/// For small edits and for files whose lines start with `-` or `+` (markdown
/// lists, notes, YAML), where unified diffs trip models up (xontel review,
/// 2026-09-28: three identical failed patches on a roadmap).
public struct EditFileTool: AgentTool {
    public let name = "edit_file"
    public let description = """
    Edit an existing file by replacing exact text: `old_text` → `new_text`. \
    Preferred for small edits, and for any file whose lines start with `-` or `+` \
    (markdown lists, notes, YAML): no diff markers needed. `old_text` must occur \
    exactly once — include a few surrounding lines to make it unique — or set \
    `replace_all`. Trailing whitespace is tolerated. If it isn't found, the error \
    shows the file's current lines near the closest match. Requires approval.
    """
    public let parameters = ToolParameters(
        properties: [
            "path": ToolParameterProperty(type: "string", description: "File to edit (a leading ~ is expanded)."),
            "old_text": ToolParameterProperty(type: "string", description: "The exact text to replace, copied from the file."),
            "new_text": ToolParameterProperty(type: "string", description: "The replacement text."),
            "replace_all": ToolParameterProperty(type: "boolean", description: "Replace every occurrence (default false: exactly one)."),
        ],
        required: ["path", "old_text", "new_text"]
    )

    public var inputExamples: [String] { [
        #"""
        {"path": "~/proj/app/naseem/roadmap.md", "old_text": "- Step 3 — session queue", "new_text": "- Step 3 — session queue (done)"}
        """#
    ] }

    public var requiresConfirmation: Bool { true }

    let policy: FileToolPolicy?
    let verifier: WriteVerifierConfig

    public init(policy: FileToolPolicy? = nil, verifier: WriteVerifierConfig = .default) {
        self.policy = policy
        self.verifier = verifier
    }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let raw = (parameters["path"] as? String), !raw.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "edit_file requires a `path`.")
        }
        guard let old = parameters["old_text"] as? String, !old.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "edit_file requires `old_text` (the exact text to replace).")
        }
        guard let new = parameters["new_text"] as? String else {
            return .error(toolCallId: "", toolName: name, message: "edit_file requires `new_text`.")
        }
        let replaceAll = boolValue(parameters["replace_all"]) ?? false
        let path = policy?.resolve(raw) ?? expandPath(raw)
        if let policy, let reason = policy.blockReason(for: path) {
            return .error(toolCallId: "", toolName: name, message: "Refusing to edit \(raw): \(reason).")
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            return .error(toolCallId: "", toolName: name,
                message: "Cannot read file to edit: \(raw). Use write_file to create a new file.")
        }
        guard let source = String(data: data, encoding: .utf8) else {
            return .error(toolCallId: "", toolName: name, message: "Not a UTF-8 text file: \(raw)")
        }

        var edited: String
        var count = source.components(separatedBy: old).count - 1
        if count > 0 {
            if count > 1 && !replaceAll {
                return .error(toolCallId: "", toolName: name, message: """
                `old_text` occurs \(count) times in \(raw). Include more surrounding lines to make it unique, \
                or set replace_all to change every occurrence. Nothing was changed.
                """)
            }
            edited = replaceAll ? source.replacingOccurrences(of: old, with: new)
                                : source.replacingCharacters(in: source.range(of: old)!, with: new)
        } else if let tolerant = Self.replaceIgnoringTrailingWhitespace(old, with: new, in: source, all: replaceAll) {
            if tolerant.count > 1 && !replaceAll {
                return .error(toolCallId: "", toolName: name, message: """
                `old_text` occurs \(tolerant.count) times in \(raw). Include more surrounding lines to make it unique, \
                or set replace_all. Nothing was changed.
                """)
            }
            edited = tolerant.result
            count = tolerant.count
        } else {
            return .error(toolCallId: "", toolName: name, message: """
            `old_text` was not found in \(raw). Nothing was changed. \(Self.nearby(old, in: source))
            """)
        }

        if let rejection = await WriteVerifier.rejection(path: path, content: edited, config: verifier) {
            return .error(toolCallId: "", toolName: name, message: """
            Edit to \(raw) REJECTED — it would leave the file broken: \(rejection.reason).

            \(rejection.guidance)
            """)
        }
        do {
            try Data(edited.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            return .error(toolCallId: "", toolName: name, message: "Write failed: \(error.localizedDescription)")
        }
        FileStateRegistry.shared.noteSeen(path: path)
        return .success(toolCallId: "", toolName: name,
            result: "Replaced \(count) occurrence\(count == 1 ? "" : "s") in \(raw).")
    }

    /// Line-wise match with trailing whitespace ignored. Returns the edited
    /// text and how many blocks matched, or nil when none did.
    static func replaceIgnoringTrailingWhitespace(_ old: String, with new: String, in source: String,
                                                  all: Bool) -> (result: String, count: Int)? {
        func rstrip(_ s: Substring) -> Substring {
            var v = s; while let l = v.last, l == " " || l == "\t" { v.removeLast() }; return v
        }
        var lines = source.components(separatedBy: "\n")
        let want = old.split(separator: "\n", omittingEmptySubsequences: false).map(rstrip)
        guard !want.isEmpty, want.count <= lines.count else { return nil }
        var starts: [Int] = []
        var i = 0
        while i + want.count <= lines.count {
            if (0..<want.count).allSatisfy({ rstrip(Substring(lines[i + $0])) == want[$0] }) { starts.append(i); i += want.count } else { i += 1 }
        }
        guard !starts.isEmpty else { return nil }
        if starts.count > 1 && !all { return ("", starts.count) }
        let replacement = new.components(separatedBy: "\n")
        for s in starts.reversed() { lines.replaceSubrange(s..<(s + want.count), with: replacement) }
        return (lines.joined(separator: "\n"), starts.count)
    }

    /// The file's lines around the closest match of `old`'s first line.
    static func nearby(_ old: String, in source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        let first = old.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !first.isEmpty, let hit = lines.firstIndex(where: { $0.contains(first) || (first.count > 12 && $0.trimmingCharacters(in: .whitespaces).hasPrefix(String(first.prefix(12)))) }) else {
            return "Read the file and copy the text exactly."
        }
        let lo = max(0, hit - 4), hi = min(lines.count - 1, hit + 6)
        return "The file's CURRENT lines near the closest match:\n\n" + (lo...hi).map { "\($0 + 1) | \(lines[$0])" }.joined(separator: "\n")
    }
}

/// List a directory's entries. Unconfirmed (read-only).
public struct ListDirTool: AgentTool {
    public let name = "list_dir"
    public var isReadOnly: Bool { true }
    public let description = "List a directory's entries. Directories are marked with a trailing slash."
    public let parameters = ToolParameters(
        properties: [
            "path": ToolParameterProperty(type: "string", description: "Directory path (default current directory)."),
            "show_hidden": ToolParameterProperty(type: "boolean", description: "Include dotfiles (default false)."),
        ],
        required: []
    )

    let policy: FileToolPolicy?

    public init(policy: FileToolPolicy? = nil) { self.policy = policy }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let raw = (parameters["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "."
        let path = policy?.resolve(raw) ?? expandPath(raw)
        if let policy, let reason = policy.blockReason(for: path) {
            return .error(toolCallId: "", toolName: name, message: "Refusing to list \(raw): \(reason).")
        }
        let showHidden = boolValue(parameters["show_hidden"]) ?? false

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return .error(toolCallId: "", toolName: name, message: "Not a directory: \(raw)")
        }
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else {
            return .error(toolCallId: "", toolName: name, message: "Cannot list: \(raw)")
        }
        let rows = entries
            .filter { showHidden || !$0.hasPrefix(".") }
            .sorted()
            .map { entry -> String in
                var sub: ObjCBool = false
                fm.fileExists(atPath: (path as NSString).appendingPathComponent(entry), isDirectory: &sub)
                return sub.boolValue ? "\(entry)/" : entry
            }
        return .success(
            toolCallId: "", toolName: name,
            result: rows.isEmpty ? "(empty)" : rows.joined(separator: "\n"))
    }
}

/// Find files under a directory by name substring and/or content substring.
/// Unconfirmed (read-only). Bounded to avoid runaway traversals.
public struct SearchFilesTool: AgentTool {
    public let name = "search_files"
    public var isReadOnly: Bool { true }
    public let description = """
    Find files under a directory. Filter by `name` (substring of the filename) \
    and/or `contains` (substring within file text). Returns absolute paths that \
    read_file opens as they are.
    """
    public let parameters = ToolParameters(
        properties: [
            "directory": ToolParameterProperty(type: "string", description: "Root directory to search (a leading ~ is expanded)."),
            "name": ToolParameterProperty(type: "string", description: "Case-insensitive substring of the filename."),
            "contains": ToolParameterProperty(type: "string", description: "Case-insensitive substring to find inside text files."),
            "max_results": ToolParameterProperty(type: "integer", description: "Maximum matches to return (default 100)."),
        ],
        required: ["directory"]
    )

    public var inputExamples: [String] { [
        #"""
        {"directory": "~/proj/app", "name": ".swift", "contains": "URLSession", "max_results": 40}
        """#,
        #"""
        {"directory": "~/proj/app/Sources", "name": "ViewModel"}
        """#
    ] }

    private let fileScanCap = 20_000

    let policy: FileToolPolicy?

    public init(policy: FileToolPolicy? = nil) { self.policy = policy }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let rawDir = (parameters["directory"] as? String), !rawDir.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "search_files requires a `directory`.")
        }
        let root = policy?.resolve(rawDir) ?? expandPath(rawDir)
        if let policy, let reason = policy.blockReason(for: root) {
            return .error(toolCallId: "", toolName: name, message: "Refusing to search \(rawDir): \(reason).")
        }
        let nameNeedle = (parameters["name"] as? String)?.lowercased()
        let contentNeedle = (parameters["contains"] as? String)?.lowercased()
        let maxResults = max(1, intValue(parameters["max_results"]) ?? 100)

        if (nameNeedle?.isEmpty ?? true) && (contentNeedle?.isEmpty ?? true) {
            return .error(toolCallId: "", toolName: name, message: "Provide `name` and/or `contains` to search for.")
        }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: root) else {
            return .error(toolCallId: "", toolName: name, message: "Cannot search: \(rawDir)")
        }

        var matches: [String] = []
        var scanned = 0
        while let rel = enumerator.nextObject() as? String {
            scanned += 1
            if scanned > fileScanCap { break }

            let full = (root as NSString).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            if isDir.boolValue { continue }

            let filename = (rel as NSString).lastPathComponent.lowercased()
            if let n = nameNeedle, !n.isEmpty, !filename.contains(n) { continue }

            if let c = contentNeedle, !c.isEmpty {
                guard let data = fm.contents(atPath: full),
                      let text = String(data: data, encoding: .utf8),
                      text.lowercased().contains(c)
                else { continue }
            }

            // Absolute: a path relative to the searched folder got joined to
            // the wrong base and failed to open (xontel review, 2026-09-28).
            matches.append(full)
            if matches.count >= maxResults { break }
        }

        if matches.isEmpty {
            return .success(toolCallId: "", toolName: name, result: "No matches under \(rawDir).")
        }
        let capped = scanned > fileScanCap ? "\n… [scan capped at \(fileScanCap) files]" : ""
        return .success(toolCallId: "", toolName: name, result: matches.joined(separator: "\n") + capped)
    }
}
