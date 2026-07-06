//
//  AgentError.swift
//  SwiftAgentKit
//

import Foundation

/// Typed errors for the agent system.
///
public enum AgentError: Error, Sendable, Equatable, LocalizedError {

    /// Maximum number of turns reached in the agent loop.
    case maxTurnsReached(Int)

    /// Maximum number of turns reached with a summary of what happened.
    case maxTurnsReachedWithSummary(Int, String)

    /// A tool with the given name was not found in the registry.
    case toolNotFound(String)

    /// Tool execution failed with an error message.
    case toolExecutionFailed(name: String, message: String)

    /// Tool execution was cancelled by the user or system.
    case toolCancelled(name: String)

    /// The LLM provider returned an error.
    case providerError(String)

    /// No LLM provider is configured or available.
    case noProviderConfigured

    /// Planning failed — the planner LLM call returned an unparseable result.
    case planningFailed(String)

    /// Repair retry limit exceeded — the model kept failing after nudges.
    case repairRetryExhausted(attempts: Int)

    /// The operation was cancelled.
    case cancelled

    /// Another run is already active on this agent instance.
    case runInProgress

    /// An unexpected error.
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .maxTurnsReached(let turns):
            return "Agent reached the maximum number of turns (\(turns)) without completing."
        case .maxTurnsReachedWithSummary(let turns, let summary):
            return "Agent reached the maximum number of turns (\(turns)).\n\(summary)"
        case .toolNotFound(let name):
            return "Tool '\(name)' was not found in the agent's tool registry."
        case .toolExecutionFailed(let name, let message):
            return "Tool '\(name)' failed: \(message)"
        case .toolCancelled(let name):
            return "Tool '\(name)' execution was cancelled."
        case .providerError(let message):
            return "LLM provider error: \(message)"
        case .noProviderConfigured:
            return "No LLM provider is configured. Add a provider to the agent before running."
        case .planningFailed(let detail):
            return "Planning failed: \(detail)"
        case .repairRetryExhausted(let attempts):
            return "Repair retry limit exceeded (\(attempts) attempts). The model kept failing after nudges."
        case .cancelled:
            return "The operation was cancelled."
        case .runInProgress:
            return "This Agent instance already has an active run. Wait for it to finish, or create a separate Agent instance for concurrent work."
        case .unknown(let message):
            return "Unknown error: \(message)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .maxTurnsReached, .maxTurnsReachedWithSummary:
            return "Try increasing `maxTurns` in the agent configuration, or simplify the task."
        case .toolNotFound:
            return "Register the tool with `agent.register(tool:)` before running the agent."
        case .toolExecutionFailed:
            return "Check the tool's parameters and try again."
        case .noProviderConfigured:
            return "Configure an LLM provider (Ollama, OpenAI, Gemini, Anthropic) and pass it to the agent."
        case .planningFailed:
            return "Check that the planner prompt is correct and the model supports JSON output."
        case .repairRetryExhausted:
            return "The model may not be capable enough. Try a larger model or simplify the task."
        case .runInProgress:
            return "Use one Agent instance per concurrent task, or serialize calls to `run(_:)`."
        default:
            return nil
        }
    }
}