//
//  AppleMailTools.swift
//  SwiftAgentKitMac
//
//  Mail.app through Apple Events. Reads are bounded (a time window, a limit,
//  a character cap) because a mailbox is unbounded. Drafting opens a message
//  in Mail for the user to look at; sending is the one action here that
//  leaves the machine, so it asks every time, autonomy or not.
//

#if os(macOS)
import Foundation
import SwiftAgentKit

public struct MailMessage: Equatable, Sendable {
    public let id: String
    public let date: Date?
    public let sender: String
    public let subject: String
    public let isRead: Bool
    public let mailbox: String
    public let account: String

    public var line: String {
        let when = date.map(AppleDates.string) ?? "?"
        return "[\(id)] \(when)  \(isRead ? "  " : "• ")\(sender) — \(subject)" + (account.isEmpty ? "" : "  (\(account)/\(mailbox))")
    }
}

public enum AppleMailScripts {
    /// Messages received in the last `hours`, newest first, up to `limit`.
    public static func inbox(hours: Int, limit: Int, unreadOnly: Bool) -> String {
        """
        \(AppleScriptText.delimiterPrelude)
        set cutoff to (current date) - (\(hours) * hours)
        set out to {}
        tell application "Mail"
            set msgs to (messages of inbox whose date received > cutoff\(unreadOnly ? " and read status is false" : ""))
            set n to count of msgs
            repeat with i from 1 to n
                set m to item i of msgs
                try
                    set acct to name of account of mailbox of m
                on error
                    set acct to ""
                end try
                set end of out to ((id of m) as string) & fs & ((date received of m as «class isot») as string) & fs & (sender of m) & fs & (subject of m) & fs & ((read status of m) as string) & fs & (name of mailbox of m) & fs & acct
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
        set out to {}
        tell application "Mail"
            set msgs to (messages of inbox whose subject contains \(q) or sender contains \(q))
            set n to count of msgs
            if n > \(limit) then set n to \(limit)
            repeat with i from 1 to n
                set m to item i of msgs
                try
                    set acct to name of account of mailbox of m
                on error
                    set acct to ""
                end try
                set end of out to ((id of m) as string) & fs & ((date received of m as «class isot») as string) & fs & (sender of m) & fs & (subject of m) & fs & ((read status of m) as string) & fs & (name of mailbox of m) & fs & acct
            end repeat
        end tell
        set AppleScript's text item delimiters to rs
        return out as string
        """
    }

    public static func read(id: String) -> String {
        """
        \(AppleScriptText.delimiterPrelude)
        tell application "Mail"
            set m to first message of inbox whose id is \(Int(id) ?? 0)
            set tos to {}
            repeat with r in to recipients of m
                set end of tos to (address of r)
            end repeat
            set AppleScript's text item delimiters to ", "
            set toLine to tos as string
            return (subject of m) & fs & (sender of m) & fs & toLine & fs & ((date received of m as «class isot») as string) & fs & (content of m)
        end tell
        """
    }

    public static func compose(to: [String], cc: [String], subject: String, body: String, send: Bool) -> String {
        let recipients = to.map { "make new to recipient at end of to recipients with properties {address:\(AppleScriptText.literal($0))}" }
            + cc.map { "make new cc recipient at end of cc recipients with properties {address:\(AppleScriptText.literal($0))}" }
        return """
        tell application "Mail"
            set msg to make new outgoing message with properties {subject:\(AppleScriptText.literal(subject)), content:\(AppleScriptText.literal(body)), visible:\(send ? "false" : "true")}
            tell msg
                \(recipients.joined(separator: "\n        "))
            end tell
            \(send ? "send msg" : "activate")
            return "ok"
        end tell
        """
    }

    public static func parseMessages(_ text: String) -> [MailMessage] {
        AppleScriptText.records(text).compactMap { f in
            guard f.count >= 7 else { return nil }
            return MailMessage(id: f[0], date: AppleScriptText.date(fromISO: f[1]), sender: f[2], subject: f[3],
                               isRead: f[4] == "true", mailbox: f[5], account: f[6])
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}

// MARK: - Tools

public struct MailInboxTool: AgentTool {
    public let name = "mail_inbox"
    public var isReadOnly: Bool { true }
    public let description = """
    Recent messages in the user's Mail inbox (all accounts), newest first: id, date, \
    sender, subject, • for unread. Bounded by `hours` (default 24) and `limit` (default 30). \
    Use the id with mail_read to get a message's text. This reads the Mail app on this Mac; \
    nothing is fetched from the network.
    """
    public let parameters = ToolParameters(properties: [
        "hours": ToolParameterProperty(type: "integer", description: "Look back this many hours (default 24, max 720)."),
        "limit": ToolParameterProperty(type: "integer", description: "Most messages to return (default 30, max 100)."),
        "unread_only": ToolParameterProperty(type: "boolean", description: "Only unread messages (default false)."),
    ], required: [])
    public var inputExamples: [String] { [#"{"hours": 24}"#, #"{"hours": 72, "unread_only": true, "limit": 20}"#] }
    let runner: any AppleScripting
    public init(runner: any AppleScripting = NSAppleScriptRunner()) { self.runner = runner }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let hours = min(max(intArg(parameters["hours"]) ?? 24, 1), 720)
        let limit = min(max(intArg(parameters["limit"]) ?? 30, 1), 100)
        let unread = (parameters["unread_only"] as? Bool) ?? false
        let text = try await runner.run(AppleMailScripts.inbox(hours: hours, limit: limit, unreadOnly: unread))
        let messages = Array(AppleMailScripts.parseMessages(text).prefix(limit))
        guard !messages.isEmpty else {
            return .success(toolCallId: "", toolName: name, result: "No \(unread ? "unread " : "")messages in the last \(hours) hours.")
        }
        return .success(toolCallId: "", toolName: name,
                        result: "\(messages.count) message(s), newest first:\n" + messages.map(\.line).joined(separator: "\n"))
    }
}

public struct MailSearchTool: AgentTool {
    public let name = "mail_search"
    public var isReadOnly: Bool { true }
    public let description = "Search the inbox by a word in the subject or the sender. Returns id, date, sender, subject; then use mail_read."
    public let parameters = ToolParameters(properties: [
        "query": ToolParameterProperty(type: "string", description: "Text to match in subject or sender."),
        "limit": ToolParameterProperty(type: "integer", description: "Most messages to return (default 20, max 100)."),
    ], required: ["query"])
    public var inputExamples: [String] { [#"{"query": "invoice"}"#] }
    let runner: any AppleScripting
    public init(runner: any AppleScripting = NSAppleScriptRunner()) { self.runner = runner }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let query = (parameters["query"] as? String)?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "query is required.")
        }
        let limit = min(max(intArg(parameters["limit"]) ?? 20, 1), 100)
        let text = try await runner.run(AppleMailScripts.search(query: query, limit: limit))
        let messages = AppleMailScripts.parseMessages(text)
        guard !messages.isEmpty else { return .success(toolCallId: "", toolName: name, result: "No inbox messages match \"\(query)\".") }
        return .success(toolCallId: "", toolName: name, result: messages.map(\.line).joined(separator: "\n"))
    }
}

public struct MailReadTool: AgentTool {
    public let name = "mail_read"
    public var isReadOnly: Bool { true }
    public let description = "Read one inbox message by the id from mail_inbox or mail_search: subject, from, to, date, and the text (capped)."
    public let parameters = ToolParameters(properties: [
        "id": ToolParameterProperty(type: "string", description: "Message id from mail_inbox / mail_search."),
        "max_chars": ToolParameterProperty(type: "integer", description: "Cap on the body (default 12000)."),
    ], required: ["id"])
    public var inputExamples: [String] { [#"{"id": "48213"}"#] }
    let runner: any AppleScripting
    public init(runner: any AppleScripting = NSAppleScriptRunner()) { self.runner = runner }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let id = stringArg(parameters["id"]), Int(id) != nil else {
            return .error(toolCallId: "", toolName: name, message: "id must be a message id from mail_inbox.")
        }
        let cap = min(max(intArg(parameters["max_chars"]) ?? 12_000, 500), 60_000)
        let text = try await runner.run(AppleMailScripts.read(id: id))
        let f = text.split(separator: AppleScriptText.field, omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 5 else { return .error(toolCallId: "", toolName: name, message: "Message \(id) was not found in the inbox.") }
        var body = f[4...].joined(separator: String(AppleScriptText.field)).trimmingCharacters(in: .whitespacesAndNewlines)
        if body.count > cap { body = String(body.prefix(cap)) + "\n… [truncated at \(cap) characters]" }
        let when = AppleScriptText.date(fromISO: f[3]).map(AppleDates.string) ?? f[3]
        return .success(toolCallId: "", toolName: name,
                        result: "Subject: \(f[0])\nFrom: \(f[1])\nTo: \(f[2])\nDate: \(when)\n\n\(body)")
    }
}

/// Opens a new message in Mail, filled in, for the user to review and send.
public struct MailDraftTool: AgentTool {
    public let name = "mail_draft"
    public let description = """
    Open a new email in the Mail app, filled in and NOT sent, so the user can read it and press \
    Send themselves. Prefer this over mail_send unless the user explicitly asked you to send.
    """
    public let parameters = ToolParameters(properties: [
        "to": ToolParameterProperty(type: "array", description: "Recipient addresses.", itemsType: "string"),
        "cc": ToolParameterProperty(type: "array", description: "CC addresses (optional).", itemsType: "string"),
        "subject": ToolParameterProperty(type: "string", description: "Subject line."),
        "body": ToolParameterProperty(type: "string", description: "Plain-text body."),
    ], required: ["to", "subject", "body"])
    public var requiresConfirmation: Bool { true }
    public var inputExamples: [String] { [#"{"to": ["sara@example.com"], "subject": "Notes from today", "body": "Hi Sara,\n\n…"}"#] }
    let runner: any AppleScripting
    public init(runner: any AppleScripting = NSAppleScriptRunner()) { self.runner = runner }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let (to, cc, subject, body) = MailCompose.arguments(parameters) else {
            return .error(toolCallId: "", toolName: name, message: "to (at least one address), subject and body are required.")
        }
        _ = try await runner.run(AppleMailScripts.compose(to: to, cc: cc, subject: subject, body: body, send: false))
        return .success(toolCallId: "", toolName: name, result: "Draft to \(to.joined(separator: ", ")) is open in Mail for the user to review. Not sent.")
    }
}

/// Sends. Leaves the machine, cannot be undone: asks every time.
public struct MailSendTool: AgentTool {
    public let name = "mail_send"
    public let description = """
    Send an email from the user's Mail account, immediately. Only when the user explicitly asked \
    you to send; otherwise use mail_draft. The user is asked to confirm every send.
    """
    public let parameters = ToolParameters(properties: [
        "to": ToolParameterProperty(type: "array", description: "Recipient addresses.", itemsType: "string"),
        "cc": ToolParameterProperty(type: "array", description: "CC addresses (optional).", itemsType: "string"),
        "subject": ToolParameterProperty(type: "string", description: "Subject line."),
        "body": ToolParameterProperty(type: "string", description: "Plain-text body."),
    ], required: ["to", "subject", "body"])
    public var requiresConfirmation: Bool { true }
    public var requiresConfirmationEvenWhenAutonomous: Bool { true }
    public var inputExamples: [String] { [#"{"to": ["sara@example.com"], "subject": "Re: invoice", "body": "Paid today, thanks."}"#] }
    let runner: any AppleScripting
    public init(runner: any AppleScripting = NSAppleScriptRunner()) { self.runner = runner }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let (to, cc, subject, body) = MailCompose.arguments(parameters) else {
            return .error(toolCallId: "", toolName: name, message: "to (at least one address), subject and body are required.")
        }
        _ = try await runner.run(AppleMailScripts.compose(to: to, cc: cc, subject: subject, body: body, send: true))
        return .success(toolCallId: "", toolName: name, result: "Sent to \(to.joined(separator: ", ")): \"\(subject)\".")
    }
}

enum MailCompose {
    static func arguments(_ p: [String: Any]) -> (to: [String], cc: [String], subject: String, body: String)? {
        let to = stringList(p["to"]).filter { $0.contains("@") }
        let cc = stringList(p["cc"]).filter { $0.contains("@") }
        guard !to.isEmpty, let subject = stringArg(p["subject"]), let body = p["body"] as? String else { return nil }
        return (to, cc, subject, body)
    }
}

// MARK: - Argument helpers shared by the Apple tools

func intArg(_ v: Any?) -> Int? {
    if let b = v as? Bool { _ = b; return nil }
    if let n = v as? NSNumber { return n.intValue }
    if let s = v as? String { return Int(s) }
    return nil
}

func stringArg(_ v: Any?) -> String? {
    if let s = v as? String { let t = s.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}

func stringList(_ v: Any?) -> [String] {
    if let a = v as? [String] { return a.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    if let a = v as? [Any] { return a.compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    if let s = v as? String { return s.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    return []
}
#endif
