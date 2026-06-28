//
//  AgentEvent.swift
//  SwiftAgentKit
//
//  Agent observability — generalized from lightweight UI logging callbacks
//  and request-summary tracking.
//

import Foundation

/// Events emitted during the agent lifecycle.
///
/// Conform to `AgentObserver` and register an observer to receive these events.
/// This is the primary observability mechanism for SwiftAgentKit —
/// you get real-time visibility into every step of the agent loop.
///
public enum AgentEvent: Sendable {

    // MARK: - Lifecycle

    /// The agent started processing a query.
    case started(query: String)

    /// The agent finished processing (successfully or with error).
    case finished(summary: AgentRunSummary)

    /// The agent was cancelled.
    case cancelled

    // MARK: - Skills

    /// Skills were activated for the current query (progressive disclosure).
    case skillsActivated(names: [String])

    // MARK: - Planning

    /// The planner started generating a plan.
    case planningStarted

    /// The planner produced a plan.
    case planGenerated(steps: [String])

    /// A plan step's status changed.
    case planStepUpdated(index: Int, step: String, status: AgentPlanStepStatus)

    // MARK: - LLM Calls

    /// About to call the LLM provider.
    case llmCallStarted(turn: Int)

    /// The LLM provider returned a response.
    case llmCallCompleted(turn: Int, response: AgentLLMResponse)

    /// An LLM call failed and will be retried.
    case llmCallRetrying(turn: Int, attempt: Int, error: String)

    /// Falling back to a different provider.
    case providerFallback(from: String, to: String)

    // MARK: - Tool Execution

    /// The model requested tool calls.
    case toolCallsReceived([AgentToolCall])

    /// A tool is about to be executed.
    case toolExecutionStarted(call: AgentToolCall)

    /// A tool finished executing.
    case toolExecutionFinished(call: AgentToolCall, result: AgentToolResult)

    /// A tool requires user confirmation.
    case toolConfirmationRequired(call: AgentToolCall, decision: @Sendable (Bool) -> Void)

    /// A tool call was skipped (duplicate in same turn).
    case toolCallSkippedDuplicate(call: AgentToolCall)

    // MARK: - Repair & Retry

    /// The repair-retry policy triggered a nudge.
    case repairRetryTriggered(errors: [AgentToolResult], attempt: Int)

    /// Plan continuation nudge.
    case planContinuationTriggered(pendingSteps: [String], attempt: Int)

    // MARK: - Memory

    /// History was trimmed to fit the context window.
    case historyTrimmed(removedCount: Int, remainingCount: Int)

    // MARK: - Streaming

    /// A streaming text chunk was received.
    case streamChunk(String)

    /// Streaming completed.
    case streamFinished
}

/// A summary of a completed agent run.
///
public struct AgentRunSummary: Sendable, Equatable {

    public let query: String
    public let totalTurns: Int
    public let toolsExecuted: Int
    public let toolErrors: Int
    public let planStepsTotal: Int
    public let planStepsCompleted: Int
    public let finalResponse: String
    public let elapsed: TimeInterval

    public init(
        query: String,
        totalTurns: Int,
        toolsExecuted: Int,
        toolErrors: Int,
        planStepsTotal: Int,
        planStepsCompleted: Int,
        finalResponse: String,
        elapsed: TimeInterval
    ) {
        self.query = query
        self.totalTurns = totalTurns
        self.toolsExecuted = toolsExecuted
        self.toolErrors = toolErrors
        self.planStepsTotal = planStepsTotal
        self.planStepsCompleted = planStepsCompleted
        self.finalResponse = finalResponse
        self.elapsed = elapsed
    }
}

/// Observer protocol — receive agent events in real time.
///
/// Usage:
/// ```swift
/// class MyObserver: AgentObserver {
///     func onEvent(_ event: AgentEvent) {
///         switch event {
///         case .started(let query): print("Agent started: \(query)")
///         case .streamChunk(let text): print(text, terminator: "")
///         // ...
///         default: break
///         }
///     }
/// }
/// let agent = Agent(provider: ollama)
/// agent.addObserver(MyObserver())
/// ```
///
public protocol AgentObserver: AnyObject, Sendable {
    func onEvent(_ event: AgentEvent)
}

/// A simple block-based observer.
///
public final class BlockObserver: AgentObserver {

    private let block: @Sendable (AgentEvent) -> Void

    public init(_ block: @Sendable @escaping (AgentEvent) -> Void) {
        self.block = block
    }

    public func onEvent(_ event: AgentEvent) {
        block(event)
    }
}