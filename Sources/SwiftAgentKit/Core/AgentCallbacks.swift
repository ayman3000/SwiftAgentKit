//
//  AgentCallbacks.swift
//  SwiftAgentKit
//
//  Lifecycle callbacks with intercept capability — inspired by
//  Google ADK's 6 lifecycle hooks.
//
//  Unlike AgentObserver (fire-only), callbacks can INTERCEPT and OVERRIDE:
//  - Return nil → proceed with default behavior
//  - Return non-nil → override (skip the action, use the returned value)
//
//  This enables: input guardrails, tool parameter validation,
//  response post-processing, token usage limits, and more.
//

import Foundation

/// Callbacks that can intercept the agent lifecycle.
///
/// Set any of these on the `Agent` to hook into the loop.
/// Return `nil` to proceed normally; return non-nil to override.
///
public struct AgentCallbacks: Sendable {

    // MARK: - Agent-level

    /// Called before the agent starts processing. Return non-nil to skip
    /// the entire agent run and use this response instead.
    ///
    /// Use case: input guardrails — block prompts containing sensitive data.
    public var beforeAgent: (@Sendable (String, AgentState) async -> String?)?

    /// Called after the agent finishes. Return non-nil to replace the
    /// final response with this string.
    ///
    /// Use case: post-processing, PII redaction, format normalization.
    public var afterAgent: (@Sendable (String, AgentState) async -> String?)?

    // MARK: - Model-level

    /// Called before each LLM call. Return non-nil to skip the LLM call
    /// and use this `AgentLLMResponse` instead.
    ///
    /// Use case: caching, token budget enforcement, prompt validation.
    public var beforeModel: (@Sendable ([AgentMessage], AgentState) async -> AgentLLMResponse?)?

    /// Called after each LLM call. Return non-nil to replace the
    /// response with this one.
    ///
    /// Use case: response filtering, safety checks, logging.
    public var afterModel: (@Sendable (AgentLLMResponse, AgentState) async -> AgentLLMResponse?)?

    // MARK: - Tool-level

    /// Called before each tool execution. Return non-nil to skip the tool
    /// and use this `AgentToolResult` instead.
    ///
    /// Use case: parameter validation, permission checks, dangerous-op blocking.
    public var beforeTool: (@Sendable (AgentToolCall, ToolContext) async -> AgentToolResult?)?

    /// Called after each tool execution. Return non-nil to replace the
    /// tool result with this one.
    ///
    /// Use case: result post-processing, error masking, format normalization.
    public var afterTool: (@Sendable (AgentToolCall, AgentToolResult, ToolContext) async -> AgentToolResult?)?

    /// Called before executing a tool whose `requiresConfirmation` is `true`
    /// (and when autonomous mode is off). Return `true` to approve execution,
    /// `false` to deny it.
    ///
    /// If a confirmation-required tool is dispatched but this callback is not
    /// set (and autonomous mode is off), the dispatcher fails closed — the tool
    /// is denied rather than run unconfirmed.
    ///
    /// Use case: human-in-the-loop approval for dangerous or irreversible ops.
    public var onToolConfirmation: (@Sendable (AgentToolCall, ToolContext) async -> Bool)?

    // MARK: - Goal-level

    /// Called when the model signals it's done (a turn with no tool calls),
    /// BEFORE the agent stops. Return a `GoalVerdict` to enforce goal-driven
    /// looping: `.satisfied` lets it stop; `.unsatisfied(reason:)` feeds the
    /// reason back as a nudge and continues the loop; `.blocked(reason:)` stops
    /// early on a real blocker. Bounded by `AgentConfig.maxVerificationRetries`.
    ///
    /// Use case: don't trust the model's "I'm done" — verify the goal is actually
    /// met (e.g. the output file exists, tests pass, the answer contains X), and
    /// keep the agent working until it is.
    ///
    /// - Parameters: the original query, the model's proposed final answer, state.
    public var verifyCompletion: (@Sendable (String, String, AgentState) async -> GoalVerdict)?

    // MARK: - Error-level

    /// Called when an LLM call fails. Return non-nil to use this as
    /// the fallback response instead of throwing.
    ///
    /// Use case: graceful degradation, provider fallback.
    public var onModelError: (@Sendable (Error, AgentState) async -> AgentLLMResponse?)?

    /// Called when a tool execution fails. Return non-nil to use this
    /// as the tool result instead of the error.
    ///
    /// Use case: error recovery, default values.
    public var onToolError: (@Sendable (AgentToolCall, Error, ToolContext) async -> AgentToolResult?)?

    public init() {}
}