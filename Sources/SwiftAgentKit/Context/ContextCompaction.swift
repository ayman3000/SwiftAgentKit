//
//  ContextCompaction.swift
//  SwiftAgentKit
//
//  Replacing the older middle of a conversation with one summary. The app
//  writes the summary (a ContextCompactor); this file decides where the
//  middle ends, how the summary rejoins the history, and which provider
//  errors mean "too long".
//

import Foundation
import LLMProviderKit

public enum CompactionReason: String, Sendable { case nearLimit, overflow }

/// Writes the summary that replaces `middle`. nil = give up (history unchanged).
public protocol ContextCompactor: Sendable {
    func summarize(middle: [AgentMessage], reason: CompactionReason) async -> String?
}

public enum ContextCompaction {
    /// Ended a summary merged into the first kept user message (alpha.109);
    /// kept so such messages can still be read.
    public static let endOfSummary = "\n\n[End of summary]\n\n"

    /// Split non-system messages into the part to summarize and the tail kept
    /// word-for-word. The tail is whole units (a user message, a plain
    /// assistant message, or an assistant tool call with its results), walked
    /// back from the newest until `tailBudget` is reached, and always at least
    /// one unit. The latest user message is always in the tail: when its turn
    /// is too big, it is pulled out and put first.
    public static func split(_ messages: [AgentMessage], tailBudget: Int,
                             estimate: (AgentMessage) -> Int) -> (middle: [AgentMessage], tail: [AgentMessage]) {
        let all = messages.filter { $0.role != .system }
        guard !all.isEmpty else { return ([], []) }
        var tailStart = all.count
        var used = 0
        var i = all.count - 1
        while i >= 0 {
            var start = i
            while start > 0 && all[start].role == .tool { start -= 1 }
            let cost = all[start...i].reduce(0) { $0 + estimate($1) }
            if used + cost > tailBudget && tailStart < all.count { break }
            used += cost
            tailStart = start
            i = start - 1
        }
        guard let lastUser = all.lastIndex(where: { $0.role == .user }), lastUser < tailStart else {
            return (Array(all[..<tailStart]), Array(all[tailStart...]))
        }
        var middle = Array(all[..<tailStart])
        middle.remove(at: lastUser)
        return (middle, [all[lastUser]] + all[tailStart...])
    }

    /// The assistant's reply after the summary, so roles keep alternating
    /// on every provider.
    public static let summaryAcknowledgement = "Understood. I'll use that summary as background and continue from your next message."

    /// The summary rejoins the history as the first message, on its own:
    /// it is written by the app, so it is never merged into a message of
    /// the user's — text it carries (say, from a web page) must not read as
    /// the user's instruction. A short acknowledgement follows when the kept
    /// part starts with a user message.
    public static func assemble(checkpoint: String, tail: [AgentMessage]) -> [AgentMessage] {
        guard let first = tail.first, first.role != .user else {
            return [.user(checkpoint), .assistant(summaryAcknowledgement)] + tail
        }
        return [.user(checkpoint)] + tail
    }

    static let overflowPhrases = [
        "context_length_exceeded", "context length", "maximum context", "context window",
        "prompt is too long", "prompt too long", "too many tokens", "input is too long",
        "exceeds the context", "exceed context", "request too large", "maximum prompt length",
    ]

    /// A provider's "this request is longer than the model takes".
    public static func isContextOverflow(_ error: Error) -> Bool {
        if let llm = error as? LLMError, case .httpError(let code, let body) = llm {
            if code == 413 { return true }
            return mentionsOverflow(body.map { String(decoding: $0, as: UTF8.self) } ?? "")
        }
        if case AgentError.providerRefused(let summary, let details) = error {
            return mentionsOverflow(summary + " " + (details ?? ""))
        }
        return mentionsOverflow(error.localizedDescription)
    }

    static func mentionsOverflow(_ text: String) -> Bool {
        let t = text.lowercased()
        return overflowPhrases.contains { t.contains($0) }
    }
}
