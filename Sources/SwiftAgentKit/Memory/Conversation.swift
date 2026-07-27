//
//  Conversation.swift
//  SwiftAgentKit
//
//  The conversation/memory abstraction — generalized from production conversation-history
//  and state-as-memory patterns.
//
//  Every app needs some form of conversation state. This provides:
//  - A message store with append/trim operations
//  - Token-aware context window management
//  - Configurable trimming strategies
//

import Foundation

/// Manages the conversation message history with context-window awareness.
///
/// This is the universal memory layer for agents. It stores messages,
/// estimates token usage, and trims history to fit the model's context window.
///
/// **Strategies**:
/// - Message-count trimming (keep last N messages)
/// - Token-budget trimming (estimate tokens, trim oldest until under budget)
/// - Per-turn context fit (trim before each LLM call to stay at ~80% capacity)
///
public class Conversation: @unchecked Sendable {

    /// The message history.
    public private(set) var messages: [AgentMessage] = []

    /// The context window size in tokens for the model being used.
    public var contextWindow: Int

    /// Maximum messages to keep (0 = unlimited).
    public var maxMessages: Int

    /// Token estimation: characters per token for the built-in heuristic.
    ///
    /// Defaults to a deliberately conservative 3.5 (rather than the looser ~4)
    /// so trimming errs toward staying *under* the real context window — code,
    /// JSON, and non-ASCII text are denser than plain English prose. For exact
    /// counts, set `tokenCounter` instead.
    public var charsPerToken: Double = 3.5

    /// Per-message framing overhead added by the built-in heuristic (role marker,
    /// message delimiters, etc.). Providers add a handful of tokens per message
    /// on top of the content itself.
    public var tokensPerMessageOverhead: Int = 4

    /// Optional exact/custom token counter. When set, it overrides the built-in
    /// heuristic used for context-window trimming — plug in a provider tokenizer
    /// (or cached results from a provider's count-tokens endpoint) for precise
    /// trimming. Must be synchronous; do not call the network from here.
    public var tokenCounter: (@Sendable (AgentMessage) -> Int)?

    /// Reserve tokens for the model's output (so history doesn't consume the entire window).
    public var outputReserve: Int = 2048

    /// Mutex for thread safety.
    private let lock = NSLock()

    public init(contextWindow: Int = 8192, maxMessages: Int = 50) {
        self.contextWindow = contextWindow
        self.maxMessages = maxMessages
    }

    // MARK: - Append

    /// Append a message to the conversation.
    public func append(_ message: AgentMessage) {
        lock.lock()
        defer { lock.unlock() }
        messages.append(message)
    }

    /// Append multiple messages.
    public func append(_ newMessages: [AgentMessage]) {
        lock.lock()
        defer { lock.unlock() }
        messages.append(contentsOf: newMessages)
    }

    // MARK: - Read

    /// Get all messages.
    public func allMessages() -> [AgentMessage] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }

    /// Get the last N messages.
    public func lastMessages(_ count: Int) -> [AgentMessage] {
        lock.lock()
        defer { lock.unlock() }
        guard messages.count > count else { return messages }
        return Array(messages.suffix(count))
    }

    /// Get messages trimmed to fit the context window.
    public func messagesForLLMCall() -> [AgentMessage] {
        lock.lock()
        defer { lock.unlock() }
        return ensureContextWindowFits(messages: messages)
    }

    // MARK: - Trim

    /// Trim history to stay within both message-count and token-budget limits.
    public func trim() -> (removed: Int, remaining: Int) {
        lock.lock()
        defer { lock.unlock() }

        var trimmed = messages

        // 1. Message-count trim — evict oldest units (keeping tool_call/tool_result
        //    pairs together) until at or under the message cap.
        if maxMessages > 0 {
            while trimmed.count > maxMessages && trimmed.contains(where: { $0.role != .system }) {
                if !removeOldestNonSystemUnit(from: &trimmed) { break }
            }
        }

        // 2. Token-budget trim
        trimmed = trimByTokens(trimmed)

        let removed = messages.count - trimmed.count
        messages = trimmed
        return (removed, messages.count)
    }

    /// Clear all messages.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        messages.removeAll()
    }

    /// Replace the system message(s) with a new one.
    public func setSystemMessage(_ message: AgentMessage) {
        lock.lock()
        defer { lock.unlock() }
        messages.removeAll { $0.role == .system }
        messages.insert(message, at: 0)
    }

    // MARK: - Token Estimation

    /// Estimate the token count for a message (including tool calls/results).
    ///
    /// Uses `tokenCounter` when set (exact), otherwise a conservative heuristic:
    /// `ceil(characterCount / charsPerToken) + tokensPerMessageOverhead`.
    public func estimateTokens(_ message: AgentMessage) -> Int {
        if let tokenCounter {
            return tokenCounter(message)
        }

        var chars = message.content.count

        if let toolCalls = message.toolCalls {
            for call in toolCalls {
                chars += call.name.count
                if let data = try? JSONEncoder().encode(call),
                   let jsonStr = String(data: data, encoding: .utf8) {
                    chars += jsonStr.count
                }
            }
        }

        if let toolResults = message.toolResults {
            for result in toolResults {
                chars += result.result.count
            }
        }

        return Int(ceil(Double(chars) / charsPerToken)) + tokensPerMessageOverhead
    }

    /// Estimate total tokens for a message array.
    public func estimateTotalTokens(_ messages: [AgentMessage]) -> Int {
        messages.reduce(0) { $0 + estimateTokens($1) }
    }

    // MARK: - Private trimming

    /// Remove the oldest evictable unit of non-system messages.
    ///
    /// An assistant message that issued tool calls is removed together with the
    /// tool-result message(s) that immediately follow it, so a `tool_result` is
    /// never left without its originating `tool_call` (and vice versa) — strict
    /// providers such as OpenAI and Anthropic reject an unpaired tool message.
    ///
    /// - Returns: `true` if a message was removed, `false` if only system
    ///   messages remain (nothing evictable).
    private func removeOldestNonSystemUnit(from messages: inout [AgentMessage]) -> Bool {
        guard let idx = messages.firstIndex(where: { $0.role != .system }) else {
            return false
        }
        let message = messages[idx]
        messages.remove(at: idx)

        // If it was an assistant turn with tool calls, drop the following
        // contiguous tool-result message(s) that answer it.
        if message.role == .assistant, let calls = message.toolCalls, !calls.isEmpty {
            while idx < messages.count && messages[idx].role == .tool {
                messages.remove(at: idx)
            }
        }
        return true
    }

    /// Trim to fit within 80% of the context window.
    private func ensureContextWindowFits(messages: [AgentMessage]) -> [AgentMessage] {
        let budget = max(0, Int(Double(contextWindow - outputReserve) * 0.8))
        var trimmed = messages

        while estimateTotalTokens(trimmed) > budget && trimmed.contains(where: { $0.role != .system }) {
            if !removeOldestNonSystemUnit(from: &trimmed) { break }
        }

        return trimmed
    }

    /// Trim oldest non-system messages until under token budget.
    private func trimByTokens(_ messages: [AgentMessage]) -> [AgentMessage] {
        let budget = max(0, contextWindow - outputReserve)
        var trimmed = messages

        while estimateTotalTokens(trimmed) > budget && trimmed.contains(where: { $0.role != .system }) {
            if !removeOldestNonSystemUnit(from: &trimmed) { break }
        }

        return trimmed
    }
}