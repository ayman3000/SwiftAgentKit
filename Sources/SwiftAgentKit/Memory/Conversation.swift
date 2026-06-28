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

    /// Token estimation: characters per token (heuristic, ~4 chars/token).
    public var charsPerToken: Double = 4.0

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

        // 1. Message-count trim
        if maxMessages > 0 && trimmed.count > maxMessages {
            let systemMessages = trimmed.filter { $0.role == .system }
            let nonSystem = trimmed.filter { $0.role != .system }
            let keepCount = maxMessages - systemMessages.count
            trimmed = systemMessages + Array(nonSystem.suffix(max(0, keepCount)))
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
    public func estimateTokens(_ message: AgentMessage) -> Int {
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

        return Int(ceil(Double(chars) / charsPerToken))
    }

    /// Estimate total tokens for a message array.
    public func estimateTotalTokens(_ messages: [AgentMessage]) -> Int {
        messages.reduce(0) { $0 + estimateTokens($1) }
    }

    // MARK: - Private trimming

    /// Trim to fit within 80% of the context window.
    private func ensureContextWindowFits(messages: [AgentMessage]) -> [AgentMessage] {
        let budget = Int(Double(contextWindow - outputReserve) * 0.8)
        var trimmed = messages
        let nonSystem = trimmed.filter { $0.role != .system }

        while estimateTotalTokens(trimmed) > budget && !nonSystem.isEmpty {
            // Remove the oldest non-system message
            if let firstNonSystemIdx = trimmed.firstIndex(where: { $0.role != .system }) {
                trimmed.remove(at: firstNonSystemIdx)
            } else {
                break
            }
        }

        return trimmed
    }

    /// Trim oldest non-system messages until under token budget.
    private func trimByTokens(_ messages: [AgentMessage]) -> [AgentMessage] {
        let budget = contextWindow - outputReserve
        var trimmed = messages

        while estimateTotalTokens(trimmed) > budget && trimmed.count > 1 {
            // Remove the oldest non-system message
            if let firstNonSystemIdx = trimmed.firstIndex(where: { $0.role != .system }) {
                trimmed.remove(at: firstNonSystemIdx)
            } else {
                break
            }
        }

        return trimmed
    }
}