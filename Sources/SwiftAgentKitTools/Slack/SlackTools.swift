//
//  SlackTools.swift
//  SwiftAgentKitTools
//
//  Slack as tools, the same shape as the Mac's own apps: reading never asks,
//  and posting asks every time — a message to a team channel leaves the Mac,
//  is seen by other people, and cannot be taken back.
//
//  Every read is bounded, because a channel is unbounded. Names are resolved
//  once per session and reused, so a run does not pay for the member list
//  on every call.
//

import Foundation
import SwiftAgentKit

/// Shared, so one run resolves channels and people once.
public actor SlackSession {
    let token: @Sendable () -> String?
    let session: URLSession
    private var channelsByName: [String: SlackAPI.Channel] = [:]
    private var userNames: [String: String] = [:]
    private var loadedUsers = false

    public init(token: @escaping @Sendable () -> String?, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    func requireToken() throws -> String {
        guard let token = token(), !token.isEmpty else {
            throw SlackAPI.SlackError.api(code: "not_authed", needed: nil)
        }
        return token
    }

    private func call(_ request: URLRequest) async throws -> [String: Any] {
        let (data, _) = try await session.data(for: request)
        return try SlackAPI.payload(data)
    }

    // A dictionary is not Sendable, so every wire call is parsed HERE and
    // only typed values leave the actor.

    func history(channel raw: String, hours: Int, limit: Int) async throws -> [SlackAPI.Message] {
        let token = try requireToken()
        let id = try await channelID(for: raw)
        let oldest = String(Date().addingTimeInterval(-Double(hours) * 3_600).timeIntervalSince1970)
        let payload = try await call(SlackAPI.get("conversations.history", token: token,
                                                  query: ["channel": id, "oldest": oldest, "limit": String(limit)]))
        return SlackAPI.messages(in: payload)
    }

    func replies(channel raw: String, ts: String) async throws -> [SlackAPI.Message] {
        let token = try requireToken()
        let id = try await channelID(for: raw)
        let payload = try await call(SlackAPI.get("conversations.replies", token: token,
                                                  query: ["channel": id, "ts": ts, "limit": "200"]))
        return SlackAPI.messages(in: payload)
    }

    func search(_ query: String, count: Int) async throws -> [SlackAPI.SearchHit] {
        let token = try requireToken()
        let payload = try await call(SlackAPI.get("search.messages", token: token,
                                                  query: ["query": query, "count": String(count)]))
        return SlackAPI.hits(in: payload)
    }

    /// Returns the posted message's timestamp.
    func post(channel raw: String, text: String, threadTS: String?) async throws -> String {
        let token = try requireToken()
        let id = try await channelID(for: raw)
        var body: [String: Any] = ["channel": id, "text": text]
        if let threadTS, !threadTS.isEmpty { body["thread_ts"] = threadTS }
        let payload = try await call(SlackAPI.post("chat.postMessage", token: token, body: body))
        return payload["ts"] as? String ?? ""
    }

    /// Channels this token can see, newest lookup cached.
    func channels(refresh: Bool = false) async throws -> [SlackAPI.Channel] {
        if !refresh, !channelsByName.isEmpty { return Array(channelsByName.values).sorted { $0.name < $1.name } }
        let payload = try await call(SlackAPI.get("conversations.list", token: try requireToken(),
                                                  query: ["types": "public_channel,private_channel",
                                                          "exclude_archived": "true",
                                                          "limit": "1000"]))
        let list = SlackAPI.channels(in: payload)
        for channel in list { channelsByName[channel.name.lowercased()] = channel }
        return list.sorted { $0.name < $1.name }
    }

    /// A name, a #name or an id — always an id by the time it reaches Slack.
    func channelID(for raw: String) async throws -> String {
        if SlackAPI.looksLikeChannelID(raw) { return raw }
        let name = SlackAPI.normalizedChannelName(raw).lowercased()
        if let hit = channelsByName[name] { return hit.id }
        _ = try await channels(refresh: true)
        guard let hit = channelsByName[name] else {
            throw SlackAPI.SlackError.api(code: "channel_not_found", needed: nil)
        }
        return hit.id
    }

    /// Display names, fetched once per session.
    func names() async -> [String: String] {
        if loadedUsers { return userNames }
        loadedUsers = true
        guard let token = try? requireToken() else { return [:] }
        if let payload = try? await call(SlackAPI.get("users.list", token: token, query: ["limit": "1000"])) {
            userNames = SlackAPI.users(in: payload)
        }
        return userNames
    }
}

// MARK: - Reading

public struct SlackChannelsTool: AgentTool {
    public let name = "slack_channels"
    public var isReadOnly: Bool { true }
    public let description = """
    List the Slack channels this workspace token can see, with their topics and whether \
    you are a member. Start here when the user names a channel you have not used yet; \
    reading a channel you have not joined is not possible.
    """
    public let parameters = ToolParameters(properties: [
        "filter": ToolParameterProperty(type: "string", description: "Only channels whose name contains this."),
    ], required: [])
    public var inputExamples: [String] { [#"{}"#, #"{"filter": "release"}"#] }
    let slack: SlackSession
    public init(slack: SlackSession) { self.slack = slack }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        do {
            var list = try await slack.channels()
            if let filter = (parameters["filter"] as? String)?.lowercased(), !filter.isEmpty {
                list = list.filter { $0.name.lowercased().contains(filter) }
            }
            guard !list.isEmpty else { return .success(toolCallId: "", toolName: name, result: "No channels match.") }
            return .success(toolCallId: "", toolName: name,
                            result: "\(list.count) channel(s):\n" + list.map(\.line).joined(separator: "\n"))
        } catch {
            return .error(toolCallId: "", toolName: name, message: error.localizedDescription)
        }
    }
}

public struct SlackHistoryTool: AgentTool {
    public let name = "slack_history"
    public var isReadOnly: Bool { true }
    public let description = """
    Read recent messages in a Slack channel, oldest first, with the sender and time. \
    Bounded by `hours` (default 24) and `limit` (default 50). A message with replies says \
    so and gives the ts to pass to slack_thread. Use the channel name (#release or release) \
    or its id.
    """
    public let parameters = ToolParameters(properties: [
        "channel": ToolParameterProperty(type: "string", description: "Channel name or id."),
        "hours": ToolParameterProperty(type: "integer", description: "Look back this many hours (default 24, max 720)."),
        "limit": ToolParameterProperty(type: "integer", description: "Most messages to return (default 50, max 200)."),
    ], required: ["channel"])
    public var inputExamples: [String] { [##"{"channel": "#incidents"}"##, ##"{"channel": "release", "hours": 72, "limit": 100}"##] }
    let slack: SlackSession
    public init(slack: SlackSession) { self.slack = slack }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let channel = parameters["channel"] as? String, !channel.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "slack_history requires a `channel`.")
        }
        let hours = min(max(intValue(parameters["hours"]) ?? 24, 1), 720)
        let limit = min(max(intValue(parameters["limit"]) ?? 50, 1), 200)
        do {
            let messages = try await slack.history(channel: channel, hours: hours, limit: limit)
            guard !messages.isEmpty else {
                return .success(toolCallId: "", toolName: name, result: "Nothing in \(channel) in the last \(hours) hours.")
            }
            let names = await slack.names()
            return .success(toolCallId: "", toolName: name,
                            result: "\(messages.count) message(s) in \(channel), oldest first:\n"
                                + messages.map { $0.line(users: names) }.joined(separator: "\n"))
        } catch {
            return .error(toolCallId: "", toolName: name, message: error.localizedDescription)
        }
    }
}

public struct SlackThreadTool: AgentTool {
    public let name = "slack_thread"
    public var isReadOnly: Bool { true }
    public let description = "Read a Slack thread: the parent message and its replies, oldest first. `ts` comes from slack_history or slack_search."
    public let parameters = ToolParameters(properties: [
        "channel": ToolParameterProperty(type: "string", description: "Channel name or id."),
        "ts": ToolParameterProperty(type: "string", description: "Timestamp of the parent message."),
    ], required: ["channel", "ts"])
    public var inputExamples: [String] { [##"{"channel": "#incidents", "ts": "1789693845.123456"}"##] }
    let slack: SlackSession
    public init(slack: SlackSession) { self.slack = slack }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let channel = parameters["channel"] as? String, let ts = parameters["ts"] as? String else {
            return .error(toolCallId: "", toolName: name, message: "slack_thread requires `channel` and `ts`.")
        }
        do {
            let messages = try await slack.replies(channel: channel, ts: ts)
            guard !messages.isEmpty else { return .success(toolCallId: "", toolName: name, result: "No thread at that timestamp.") }
            let names = await slack.names()
            return .success(toolCallId: "", toolName: name,
                            result: messages.map { $0.line(users: names) }.joined(separator: "\n"))
        } catch {
            return .error(toolCallId: "", toolName: name, message: error.localizedDescription)
        }
    }
}

public struct SlackSearchTool: AgentTool {
    public let name = "slack_search"
    public var isReadOnly: Bool { true }
    public let description = """
    Search Slack messages the way the search box does, across every channel and DM this \
    token can see. Slack's own modifiers work: `in:#channel`, `from:@someone`, `after:2026-09-01`. \
    Returns the channel, sender, time and text, with the ts for slack_thread.
    """
    public let parameters = ToolParameters(properties: [
        "query": ToolParameterProperty(type: "string", description: "What to search for; Slack modifiers allowed."),
        "limit": ToolParameterProperty(type: "integer", description: "Most results (default 20, max 100)."),
    ], required: ["query"])
    public var inputExamples: [String] { [#"{"query": "deploy failed in:#incidents"}"#] }
    let slack: SlackSession
    public init(slack: SlackSession) { self.slack = slack }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let query = (parameters["query"] as? String)?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "slack_search requires a `query`.")
        }
        let limit = min(max(intValue(parameters["limit"]) ?? 20, 1), 100)
        do {
            let hits = try await slack.search(query, count: limit)
            guard !hits.isEmpty else { return .success(toolCallId: "", toolName: name, result: "Nothing in Slack matches \"\(query)\".") }
            let names = await slack.names()
            return .success(toolCallId: "", toolName: name,
                            result: hits.map { $0.line(users: names) }.joined(separator: "\n"))
        } catch {
            return .error(toolCallId: "", toolName: name, message: error.localizedDescription)
        }
    }
}

// MARK: - Writing

/// Posting is seen by other people and cannot be taken back: it asks every
/// time, autonomy or not, exactly like sending mail.
public struct SlackPostTool: AgentTool {
    public let name = "slack_post"
    public let description = """
    Post a message to a Slack channel, or reply in a thread by passing `thread_ts`. It is \
    sent as the user, immediately, and everyone in the channel sees it. Write the message \
    in full and show it to the user before calling this. The user confirms every post.
    """
    public let parameters = ToolParameters(properties: [
        "channel": ToolParameterProperty(type: "string", description: "Channel name or id."),
        "text": ToolParameterProperty(type: "string", description: "The message. Slack markdown."),
        "thread_ts": ToolParameterProperty(type: "string", description: "Reply inside this thread (optional)."),
    ], required: ["channel", "text"])
    public var requiresConfirmation: Bool { true }
    public var requiresConfirmationEvenWhenAutonomous: Bool { true }
    public var inputExamples: [String] { [##"{"channel": "#release", "text": "Naseem 1.12.0 is out."}"##] }
    let slack: SlackSession
    public init(slack: SlackSession) { self.slack = slack }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let channel = parameters["channel"] as? String, !channel.isEmpty,
              let text = parameters["text"] as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "slack_post requires `channel` and `text`.")
        }
        do {
            let thread = (parameters["thread_ts"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let ts = try await slack.post(channel: channel, text: text, threadTS: thread)
            return .success(toolCallId: "", toolName: name,
                            result: "Posted to \(channel)\(thread != nil ? " (in thread)" : "").\(ts.isEmpty ? "" : " ts: \(ts)")")
        } catch {
            return .error(toolCallId: "", toolName: name, message: error.localizedDescription)
        }
    }
}

/// Every Slack tool, for a host that has a token.
public func makeSlackTools(token: @escaping @Sendable () -> String?, session: URLSession = .shared) -> [any AgentTool] {
    let slack = SlackSession(token: token, session: session)
    return [SlackChannelsTool(slack: slack), SlackHistoryTool(slack: slack), SlackThreadTool(slack: slack),
            SlackSearchTool(slack: slack), SlackPostTool(slack: slack)]
}

/// System-prompt guidance the host appends when Slack is on.
public func slackPromptGuidance() -> String {
    """
    - Slack (slack_channels, slack_history, slack_thread, slack_search, slack_post): reading \
    is free and bounded — start from slack_channels when you do not know the channel, and \
    prefer slack_search when the user describes something rather than naming where it is. \
    Posting is seen by other people and cannot be taken back: write the message out in the \
    conversation first, let the user read it, and only then call slack_post, which asks them \
    every time. Never post to a channel the user did not name.
    """
}
