//
//  SlackAPI.swift
//  SwiftAgentKitTools
//
//  The wire: requests built and responses read, with no networking here, so
//  every shape is checked by a test. The tools do the sending.
//
//  Naseem talks to Slack as the USER, with a token the user pasted, so it
//  sees exactly what they see and there is no bot to invite into channels.
//  Slack answers every call with {"ok": true|false, "error": "..."}; an
//  error code is turned into a sentence that says what to do about it.
//

import Foundation

public enum SlackAPI {
    public static let base = URL(string: "https://slack.com/api/")!

    // MARK: Requests

    public static func get(_ method: String, token: String, query: [String: String] = [:],
                           base: URL = SlackAPI.base) -> URLRequest {
        var components = URLComponents(url: base.appendingPathComponent(method), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        return request
    }

    public static func post(_ method: String, token: String, body: [String: Any],
                            base: URL = SlackAPI.base) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(method))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30
        return request
    }

    // MARK: Responses

    /// Slack reports failure in the body, not the status code.
    public static func payload(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SlackError.unreadable
        }
        if json["ok"] as? Bool == true { return json }
        throw SlackError.api(code: json["error"] as? String ?? "unknown",
                             needed: (json["needed"] as? String) ?? (json["response_metadata"] as? [String: Any])
                                .flatMap { ($0["scopes"] as? [String])?.joined(separator: ", ") })
    }

    public enum SlackError: LocalizedError, Equatable {
        case unreadable
        case api(code: String, needed: String?)

        public var errorDescription: String? {
            switch self {
            case .unreadable:
                "Slack sent something this tool could not read."
            case .api(let code, let needed):
                SlackAPI.sentence(for: code, needed: needed)
            }
        }
    }

    /// A Slack error code as a sentence the user can act on. Pure — tested.
    public static func sentence(for code: String, needed: String? = nil) -> String {
        switch code {
        case "not_authed", "invalid_auth", "token_revoked", "account_inactive":
            return "Slack rejected the token. Paste a current user token (it begins xoxp-) in Settings ▸ Integrations ▸ Slack."
        case "missing_scope":
            let scope = needed.map { " It needs: \($0)." } ?? ""
            return "The Slack token is missing a permission.\(scope) Add the scope under User Token Scopes on your app's OAuth & Permissions page, reinstall the app, and paste the new token."
        case "not_in_channel":
            return "You are not a member of that channel, so the token cannot read it. Join the channel in Slack and try again."
        case "channel_not_found":
            return "No channel by that name. Use slack_channels to list the ones this token can see."
        case "is_archived":
            return "That channel is archived."
        case "msg_too_long":
            return "The message is too long for Slack."
        case "rate_limited", "ratelimited":
            return "Slack is rate-limiting this token. Wait a moment and try again."
        case "no_permission", "restricted_action":
            return "This workspace does not allow that action with this token."
        default:
            return "Slack refused the request (\(code))."
        }
    }

    // MARK: Values

    /// Slack timestamps are epoch seconds with microseconds after a dot, and
    /// double as message ids. Pure — tested.
    public static func date(fromTS ts: String) -> Date? {
        guard let seconds = Double(ts.split(separator: ".").first.map(String.init) ?? ts) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    public static func clock(_ ts: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date = date(fromTS: ts) else { return ts }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "d MMM HH:mm"
        return formatter.string(from: date)
    }

    /// Slack writes mentions as <@U123>, links as <https://x|text>, and
    /// channels as <#C123|name>. Turn them back into something readable.
    /// Pure — tested.
    public static func readable(_ text: String, users: [String: String] = [:]) -> String {
        var out = text
        for (id, name) in users {
            out = out.replacingOccurrences(of: "<@\(id)>", with: "@\(name)")
        }
        out = out.replacingOccurrences(of: #"<@([UW][A-Z0-9]+)>"#, with: "@$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"<#[A-Z0-9]+\|([^>]*)>"#, with: "#$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"<(https?://[^>|]+)\|([^>]*)>"#, with: "$2 ($1)", options: .regularExpression)
        out = out.replacingOccurrences(of: #"<(https?://[^>]+)>"#, with: "$1", options: .regularExpression)
        return out.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    /// "#general", "general" and "C0123" all name the same channel. Pure.
    public static func normalizedChannelName(_ raw: String) -> String {
        raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
    }

    public static func looksLikeChannelID(_ raw: String) -> Bool {
        raw.count >= 9 && (raw.hasPrefix("C") || raw.hasPrefix("G") || raw.hasPrefix("D"))
            && raw.uppercased() == raw && !raw.contains(" ")
    }

    // MARK: Shapes

    public struct Channel: Equatable, Sendable {
        public let id: String
        public let name: String
        public let isPrivate: Bool
        public let isMember: Bool
        public let topic: String?
        public var line: String {
            var s = "#\(name)\(isPrivate ? " (private)" : "")"
            if !isMember { s += " — not joined" }
            if let topic, !topic.isEmpty { s += " — \(topic)" }
            return s
        }
    }

    public static func channels(in payload: [String: Any]) -> [Channel] {
        (payload["channels"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let id = raw["id"] as? String, let name = raw["name"] as? String else { return nil }
            let topic = (raw["topic"] as? [String: Any])?["value"] as? String
            return Channel(id: id, name: name,
                           isPrivate: raw["is_private"] as? Bool ?? false,
                           isMember: raw["is_member"] as? Bool ?? true,
                           topic: topic)
        }
    }

    public struct Message: Equatable, Sendable {
        public let ts: String
        public let user: String
        public let text: String
        public let threadTS: String?
        public let replyCount: Int
        /// Oldest first, the way a person reads a channel.
        public func line(users: [String: String], now: Date = Date()) -> String {
            let name = users[user].map { "@\($0)" } ?? (user.isEmpty ? "(unknown)" : "@\(user)")
            var s = "[\(clock(ts, now: now))] \(name): \(readable(text, users: users))"
            if replyCount > 0 { s += "  (\(replyCount) repl\(replyCount == 1 ? "y" : "ies") — slack_thread ts: \(ts))" }
            return s
        }
    }

    public static func messages(in payload: [String: Any], key: String = "messages") -> [Message] {
        (payload[key] as? [[String: Any]] ?? []).compactMap { raw in
            guard let ts = raw["ts"] as? String else { return nil }
            return Message(ts: ts,
                           user: (raw["user"] as? String) ?? (raw["username"] as? String) ?? (raw["bot_id"] as? String) ?? "",
                           text: raw["text"] as? String ?? "",
                           threadTS: raw["thread_ts"] as? String,
                           replyCount: raw["reply_count"] as? Int ?? 0)
        }
        .sorted { $0.ts < $1.ts }
    }

    public struct SearchHit: Equatable, Sendable {
        public let channel: String
        public let ts: String
        public let user: String
        public let text: String
        public func line(users: [String: String], now: Date = Date()) -> String {
            let who = users[user].map { "@\($0)" } ?? (user.isEmpty ? "(unknown)" : "@\(user)")
            return "#\(channel) [\(clock(ts, now: now))] \(who): \(readable(text, users: users))  (ts: \(ts))"
        }
    }

    public static func hits(in payload: [String: Any]) -> [SearchHit] {
        let matches = (payload["messages"] as? [String: Any])?["matches"] as? [[String: Any]] ?? []
        return matches.compactMap { raw in
            guard let ts = raw["ts"] as? String else { return nil }
            return SearchHit(channel: (raw["channel"] as? [String: Any])?["name"] as? String ?? "?",
                             ts: ts,
                             user: (raw["user"] as? String) ?? (raw["username"] as? String) ?? "",
                             text: raw["text"] as? String ?? "")
        }
    }

    public static func users(in payload: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for raw in payload["members"] as? [[String: Any]] ?? [] {
            guard let id = raw["id"] as? String else { continue }
            let profile = raw["profile"] as? [String: Any]
            out[id] = (profile?["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (profile?["real_name"] as? String)
                ?? (raw["name"] as? String)
                ?? id
        }
        return out
    }
}
