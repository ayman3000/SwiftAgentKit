//
//  AppleNotesTools.swift
//  SwiftAgentKitMac
//
//  Notes.app through Apple Events. Listing asks for every note's id, name
//  and date in three bulk requests — one round trip each — rather than one
//  request per note, because a notes library is often a thousand items.
//

#if os(macOS)
import Foundation
import SwiftAgentKit

public struct NoteSummary: Equatable, Sendable {
    public let id: String
    public let name: String
    public let modified: Date?
    public let folder: String
    public var line: String {
        "[\(shortID)] \(modified.map(AppleDates.string) ?? "?")  \(name)" + (folder.isEmpty ? "" : "  (\(folder))")
    }
    /// Note ids are long Core Data URLs; the tail is enough to tell them apart
    /// in a list, and notes_read accepts either form.
    var shortID: String { id.components(separatedBy: "/").last ?? id }
}

public enum AppleNotesScripts {
    public static func list(folder: String?, limit: Int) -> String {
        let source = folder.map { "notes of folder \(AppleScriptText.literal($0))" } ?? "notes"
        // `dates` and `folders` are class plurals in Notes' dictionary; plain
        // names collide with them ("Can't set every date…").
        return """
        \(AppleScriptText.delimiterPrelude)
        \(AppleScriptText.launchGuard("Notes"))
        set out to {}
        with timeout of 120 seconds
        tell application "Notes"
            set nIDs to id of \(source)
            set nNames to name of \(source)
            set nDates to modification date of \(source)
            set nFolders to name of container of \(source)
            repeat with i from 1 to count of nIDs
                set end of out to (item i of nIDs) & fs & (item i of nNames) & fs & ((item i of nDates as «class isot») as string) & fs & (item i of nFolders)
            end repeat
        end tell
        end timeout
        set AppleScript's text item delimiters to rs
        return out as string
        """
    }

    public static func folders() -> String {
        """
        \(AppleScriptText.delimiterPrelude)
        \(AppleScriptText.launchGuard("Notes"))
        tell application "Notes"
            set out to {}
            repeat with f in folders
                set end of out to (name of f) & fs & ((count of notes of f) as string)
            end repeat
        end tell
        set AppleScript's text item delimiters to rs
        return out as string
        """
    }

    public static func search(query: String, limit: Int) -> String {
        let q = AppleScriptText.literal(query)
        return """
        \(AppleScriptText.delimiterPrelude)
        \(AppleScriptText.launchGuard("Notes"))
        set out to {}
        tell application "Notes"
            set hits to (notes whose name contains \(q) or plaintext contains \(q))
            set n to count of hits
            if n > \(limit) then set n to \(limit)
            repeat with i from 1 to n
                set nt to item i of hits
                set end of out to (id of nt) & fs & (name of nt) & fs & ((modification date of nt as «class isot») as string) & fs & (name of container of nt)
            end repeat
        end tell
        set AppleScript's text item delimiters to rs
        return out as string
        """
    }

    /// Accepts a full id or the tail shown in lists.
    public static func read(id: String) -> String {
        let q = AppleScriptText.literal(id)
        return """
        \(AppleScriptText.delimiterPrelude)
        \(AppleScriptText.launchGuard("Notes"))
        tell application "Notes"
            set hits to (notes whose id ends with \(q))
            if (count of hits) is 0 then error "No note with that id." number 9001
            set nt to item 1 of hits
            return (name of nt) & fs & (name of container of nt) & fs & ((modification date of nt as «class isot») as string) & fs & (plaintext of nt)
        end tell
        """
    }

    public static func create(title: String, body: String, folder: String?) -> String {
        // Notes bodies are HTML; paragraphs become <div>s so line breaks survive.
        let paragraphs = body.components(separatedBy: "\n").map { line -> String in
            let escaped = line.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            return escaped.isEmpty ? "<div><br></div>" : "<div>\(escaped)</div>"
        }.joined()
        let html = "<h1>\(title.replacingOccurrences(of: "<", with: "&lt;"))</h1>" + paragraphs
        let target = folder.map { "at folder \(AppleScriptText.literal($0))" } ?? ""
        return """
        \(AppleScriptText.launchGuard("Notes"))
        tell application "Notes"
            set nt to make new note \(target) with properties {body:\(AppleScriptText.literal(html))}
            return id of nt
        end tell
        """
    }

    /// Notes deleted this way go to the Notes app's Recently Deleted folder,
    /// which is the closest thing to an undo any of these apps offer.
    public static func delete(id: String) -> String {
        let q = AppleScriptText.literal(id)
        return """
        \(AppleScriptText.launchGuard("Notes"))
        tell application "Notes"
            set hits to (notes whose id ends with \(q))
            if (count of hits) is 0 then error "No note with that id." number 9001
            set nt to item 1 of hits
            set nm to name of nt
            delete nt
            return nm
        end tell
        """
    }

    public static func parseSummaries(_ text: String) -> [NoteSummary] {
        AppleScriptText.records(text).compactMap { f in
            guard f.count >= 4 else { return nil }
            // A note at the account root has no container: "missing value".
            return NoteSummary(id: f[0], name: f[1], modified: AppleScriptText.date(fromISO: f[2]),
                               folder: f[3] == "missing value" ? "" : f[3])
        }
        .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }
}

public struct NotesListTool: AgentTool {
    public let name = "notes_list"
    public var isReadOnly: Bool { true }
    public let description = """
    The user's notes in the Notes app, most recently edited first (id, date, title, folder), \
    plus the folders. Pass `folder` to list one folder. Bounded by `limit` (default 30). \
    Use notes_read with an id for a note's text.
    """
    public let parameters = ToolParameters(properties: [
        "folder": ToolParameterProperty(type: "string", description: "A folder name to list (optional)."),
        "limit": ToolParameterProperty(type: "integer", description: "Most notes to return (default 30, max 200)."),
    ], required: [])
    public var inputExamples: [String] { [#"{}"#, #"{"folder": "Work", "limit": 50}"#] }
    let runner: any AppleScripting
    public init(runner: any AppleScripting = NSAppleScriptRunner()) { self.runner = runner }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let limit = min(max(intArg(parameters["limit"]) ?? 30, 1), 200)
        let folder = stringArg(parameters["folder"])
        let notes = Array(AppleNotesScripts.parseSummaries(try await runner.run(AppleNotesScripts.list(folder: folder, limit: limit))).prefix(limit))
        var out = ""
        if folder == nil {
            let folders = AppleScriptText.records(try await runner.run(AppleNotesScripts.folders()))
                .filter { $0.count >= 2 }.map { "\($0[0]) (\($0[1]))" }
            if !folders.isEmpty { out += "Folders: " + folders.joined(separator: ", ") + "\n\n" }
        }
        out += notes.isEmpty ? "No notes\(folder.map { " in \"\($0)\"" } ?? "")." : notes.map(\.line).joined(separator: "\n")
        return .success(toolCallId: "", toolName: name, result: out)
    }
}

public struct NotesSearchTool: AgentTool {
    public let name = "notes_search"
    public var isReadOnly: Bool { true }
    public let description = "Find notes whose title or text contains a word. Returns id, date, title, folder; then use notes_read."
    public let parameters = ToolParameters(properties: [
        "query": ToolParameterProperty(type: "string", description: "Text to look for."),
        "limit": ToolParameterProperty(type: "integer", description: "Most notes to return (default 20, max 100)."),
    ], required: ["query"])
    public var inputExamples: [String] { [#"{"query": "quarterly plan"}"#] }
    let runner: any AppleScripting
    public init(runner: any AppleScripting = NSAppleScriptRunner()) { self.runner = runner }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let query = stringArg(parameters["query"]) else { return .error(toolCallId: "", toolName: name, message: "query is required.") }
        let limit = min(max(intArg(parameters["limit"]) ?? 20, 1), 100)
        let notes = AppleNotesScripts.parseSummaries(try await runner.run(AppleNotesScripts.search(query: query, limit: limit)))
        guard !notes.isEmpty else { return .success(toolCallId: "", toolName: name, result: "No notes contain \"\(query)\".") }
        return .success(toolCallId: "", toolName: name, result: notes.map(\.line).joined(separator: "\n"))
    }
}

public struct NotesReadTool: AgentTool {
    public let name = "notes_read"
    public var isReadOnly: Bool { true }
    public let description = "Read one note by the id from notes_list or notes_search: title, folder, date, and its text (capped)."
    public let parameters = ToolParameters(properties: [
        "id": ToolParameterProperty(type: "string", description: "Note id (as shown in a list)."),
        "max_chars": ToolParameterProperty(type: "integer", description: "Cap on the text (default 20000)."),
    ], required: ["id"])
    public var inputExamples: [String] { [#"{"id": "p1234"}"#] }
    let runner: any AppleScripting
    public init(runner: any AppleScripting = NSAppleScriptRunner()) { self.runner = runner }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let id = stringArg(parameters["id"]) else { return .error(toolCallId: "", toolName: name, message: "id is required.") }
        let cap = min(max(intArg(parameters["max_chars"]) ?? 20_000, 500), 80_000)
        let f = (try await runner.run(AppleNotesScripts.read(id: id))).split(separator: AppleScriptText.field, omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 4 else { return .error(toolCallId: "", toolName: name, message: "Note \(id) was not found.") }
        var body = f[3...].joined(separator: String(AppleScriptText.field)).trimmingCharacters(in: .whitespacesAndNewlines)
        if body.count > cap { body = String(body.prefix(cap)) + "\n… [truncated at \(cap) characters]" }
        let when = AppleScriptText.date(fromISO: f[2]).map(AppleDates.string) ?? f[2]
        return .success(toolCallId: "", toolName: name, result: "Title: \(f[0])\nFolder: \(f[1])\nEdited: \(when)\n\n\(body)")
    }
}

public struct NotesCreateTool: AgentTool {
    public let name = "notes_create"
    public let description = "Create a note in the Notes app with a title and plain-text body, optionally in a named folder. Confirmed by the user."
    public let parameters = ToolParameters(properties: [
        "title": ToolParameterProperty(type: "string", description: "The note's title (first line)."),
        "body": ToolParameterProperty(type: "string", description: "Plain text; line breaks are kept."),
        "folder": ToolParameterProperty(type: "string", description: "Folder name (optional; default folder otherwise)."),
    ], required: ["title", "body"])
    public var requiresConfirmation: Bool { true }
    public var inputExamples: [String] { [#"{"title": "Meeting notes 19 Sep", "body": "Decisions:\n- …", "folder": "Work"}"#] }
    let runner: any AppleScripting
    public init(runner: any AppleScripting = NSAppleScriptRunner()) { self.runner = runner }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let title = stringArg(parameters["title"]), let body = parameters["body"] as? String else {
            return .error(toolCallId: "", toolName: name, message: "title and body are required.")
        }
        let folder = stringArg(parameters["folder"])
        let id = try await runner.run(AppleNotesScripts.create(title: title, body: body, folder: folder))
        return .success(toolCallId: "", toolName: name, result: "Created note \"\(title)\"\(folder.map { " in \($0)" } ?? "") [\(id.components(separatedBy: "/").last ?? id)].")
    }
}
public struct NotesDeleteTool: AgentTool {
    public let name = "notes_delete"
    public let description = """
    Delete a note, by the id from notes_list or notes_search. It goes to the Notes app's \
    Recently Deleted folder, where the user can restore it for a while. Read the note first if \
    there is any doubt which one is meant. The user is asked to confirm every deletion.
    """
    public let parameters = ToolParameters(properties: [
        "id": ToolParameterProperty(type: "string", description: "Note id (as shown in a list)."),
    ], required: ["id"])
    public var requiresConfirmation: Bool { true }
    public var requiresConfirmationEvenWhenAutonomous: Bool { true }
    public var inputExamples: [String] { [#"{"id": "p152"}"#] }
    let runner: any AppleScripting
    public init(runner: any AppleScripting = NSAppleScriptRunner()) { self.runner = runner }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let id = stringArg(parameters["id"]) else { return .error(toolCallId: "", toolName: name, message: "id is required.") }
        let name_ = try await runner.run(AppleNotesScripts.delete(id: id))
        return .success(toolCallId: "", toolName: name, result: "Deleted the note \"\(name_)\". It is in Recently Deleted in the Notes app if the user wants it back.")
    }
}
#endif
