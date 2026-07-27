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
    public let description = """
    Read a UTF-8 text file and return its contents. Use `offset` and `limit` to \
    page through large files.
    """
    public let parameters = ToolParameters(
        properties: [
            "path": ToolParameterProperty(type: "string", description: "File path (a leading ~ is expanded)."),
            "offset": ToolParameterProperty(type: "integer", description: "Start character offset (default 0)."),
            "limit": ToolParameterProperty(type: "integer", description: "Max characters to read (default 40000)."),
        ],
        required: ["path"]
    )

    public init() {}

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let raw = (parameters["path"] as? String), !raw.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "read_file requires a `path`.")
        }
        let path = expandPath(raw)
        guard let data = FileManager.default.contents(atPath: path) else {
            return .error(toolCallId: "", toolName: name, message: "Cannot read file: \(raw)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .error(toolCallId: "", toolName: name, message: "Not a UTF-8 text file: \(raw)")
        }
        let chars = Array(text)
        let offset = max(0, intValue(parameters["offset"]) ?? 0)
        let limit = intValue(parameters["limit"]) ?? 40_000
        let start = min(offset, chars.count)
        let end = min(start + max(0, limit), chars.count)
        var slice = String(chars[start..<end])
        if end < chars.count {
            slice += "\n… [truncated at \(end)/\(chars.count) chars — call again with offset \(end)]"
        }
        return .success(toolCallId: "", toolName: name, result: slice)
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

    public var requiresConfirmation: Bool { true }

    public init() {}

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let raw = (parameters["path"] as? String), !raw.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "write_file requires a `path`.")
        }
        guard let content = parameters["content"] as? String else {
            return .error(toolCallId: "", toolName: name, message: "write_file requires `content`.")
        }
        let path = expandPath(raw)
        let url = URL(fileURLWithPath: path)
        let append = boolValue(parameters["append"]) ?? false

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

            if append, FileManager.default.fileExists(atPath: path) {
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
        let verb = append ? "Appended" : "Wrote"
        return .success(toolCallId: "", toolName: name, result: "\(verb) \(content.utf8.count) bytes to \(raw).")
    }
}

/// List a directory's entries. Unconfirmed (read-only).
public struct ListDirTool: AgentTool {
    public let name = "list_dir"
    public let description = "List a directory's entries. Directories are marked with a trailing slash."
    public let parameters = ToolParameters(
        properties: [
            "path": ToolParameterProperty(type: "string", description: "Directory path (default current directory)."),
            "show_hidden": ToolParameterProperty(type: "boolean", description: "Include dotfiles (default false)."),
        ],
        required: []
    )

    public init() {}

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let raw = (parameters["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "."
        let path = expandPath(raw)
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
    public let description = """
    Find files under a directory. Filter by `name` (substring of the filename) \
    and/or `contains` (substring within file text). Returns matching paths.
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

    private let fileScanCap = 20_000

    public init() {}

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let rawDir = (parameters["directory"] as? String), !rawDir.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "search_files requires a `directory`.")
        }
        let root = expandPath(rawDir)
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

            matches.append(rel)
            if matches.count >= maxResults { break }
        }

        if matches.isEmpty {
            return .success(toolCallId: "", toolName: name, result: "No matches under \(rawDir).")
        }
        let capped = scanned > fileScanCap ? "\n… [scan capped at \(fileScanCap) files]" : ""
        return .success(toolCallId: "", toolName: name, result: matches.joined(separator: "\n") + capped)
    }
}
