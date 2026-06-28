//
//  ToolContext.swift
//  SwiftAgentKit
//
//  Rich context object injected into every tool call — inspired by
//  Google ADK's `ToolContext`.
//
//  Instead of tools getting a bare `[String: Any]`, they get a ToolContext
//  with access to:
//  - Agent state (read/write cross-turn variables)
//  - The current tool call info (name, parameters, call ID)
//  - The current turn number
//  - The query that started this run
//  - Actions the tool can request (e.g., skip summarization)
//

import Foundation

/// A rich context object passed to every tool execution.
///
/// This gives tools access to the agent's state, the current call details,
/// and the ability to request actions — without coupling tools to the
/// `Agent` class itself.
///
/// Usage in a tool:
/// ```swift
/// func execute(context: ToolContext) async throws -> AgentToolResult {
///     let path = context.parameters["path"] as? String ?? ""
///     let userId = context.state.string(forKey: "user:id") ?? "unknown"
///     context.state.setValue(Date(), forKey: "temp:last_access")
///     return .success(toolCallId: context.callId, toolName: context.toolName, result: "...")
/// }
/// ```
///
public struct ToolContext: @unchecked Sendable {

    /// The tool call ID (for result correlation).
    public let callId: String

    /// The tool name being executed.
    public let toolName: String

    /// The decoded parameters as `[String: Any]`.
    public let parameters: [String: Any]

    /// Agent state — read/write cross-turn variables.
    public let state: AgentState

    /// The current turn number in the agent loop (0-indexed).
    public let turn: Int

    /// The original query that started this agent run.
    public let query: String

    /// Actions the tool can request from the agent.
    public var actions: ToolActions

    public init(
        callId: String,
        toolName: String,
        parameters: [String: Any],
        state: AgentState,
        turn: Int = 0,
        query: String = "",
        actions: ToolActions = ToolActions()
    ) {
        self.callId = callId
        self.toolName = toolName
        self.parameters = parameters
        self.state = state
        self.turn = turn
        self.query = query
        self.actions = actions
    }
}

/// Actions a tool can request from the agent loop.
///
public struct ToolActions: Sendable {

    /// If true, the agent should skip LLM summarization of this tool's output
    /// and feed it directly into the next turn's context.
    public var skipSummarization: Bool

    /// If true, the tool result indicates the agent should stop the loop
    /// after this turn (e.g., a tool that determined the task is complete).
    public var shouldStop: Bool

    /// If true, the tool result indicates an error that should trigger
    /// the repair-retry policy.
    public var shouldRetry: Bool

    public init(skipSummarization: Bool = false, shouldStop: Bool = false, shouldRetry: Bool = false) {
        self.skipSummarization = skipSummarization
        self.shouldStop = shouldStop
        self.shouldRetry = shouldRetry
    }
}