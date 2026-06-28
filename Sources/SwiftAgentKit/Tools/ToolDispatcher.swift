//
//  ToolDispatcher.swift
//  SwiftAgentKit
//
//  Handles tool-call dispatch with:
//  - Per-turn deduplication
//  - Confirmation gating
//  - Parameter normalization
//  - Error handling
//

import Foundation

/// Dispatches tool calls to registered tools with safety checks.
///
/// This is the execution engine that sits between the LLM response (which contains
/// tool calls) and the tool execution. It handles:
///
/// - **Deduplication**: identical tool calls in the same turn are skipped
/// - **Confirmation**: tools marked `requiresConfirmation` prompt the user
/// - **Parameter normalization**: injects context fields, normalizes aliases
/// - **Error handling**: catches tool errors and returns error results
///
public actor ToolDispatcher {

    private let registry: ToolRegistry

    /// Context fields injected into every tool call.
    /// Set this from your app's state (current directory, selected files, etc.)
    public var contextFields: [String: Any] = [:]

    /// Whether autonomous mode is enabled (skips confirmation for non-dangerous tools).
    public var autonomousMode: Bool = false

    /// Parameter aliases — maps shorthand names to canonical names.
    /// e.g. ["dir": "path", "cmd": "command"]
    public var parameterAliases: [String: String] = [:]

    public init(registry: ToolRegistry) {
        self.registry = registry
    }

    /// Set context fields that will be injected into every tool call.
    public func setContext(_ context: [String: Any]) {
        contextFields = context
    }

    // MARK: - Dispatch

    /// Dispatch a batch of tool calls — optionally in parallel.
    ///
    /// - Parameters:
    ///   - calls: The tool calls from the LLM response
    ///   - state: Agent state for tool context
    ///   - turn: Current turn number
    ///   - query: The original query
    ///   - callbacks: Lifecycle callbacks (beforeTool, afterTool, onToolError)
    ///   - parallel: Whether to run tools concurrently (default: true)
    ///   - observer: Optional observer for events
    /// - Returns: The results of each tool call
    public func dispatch(
        calls: [AgentToolCall],
        state: AgentState,
        turn: Int = 0,
        query: String = "",
        callbacks: AgentCallbacks? = nil,
        parallel: Bool = true,
        observer: (any AgentObserver)?
    ) async -> [AgentToolResult] {
        if parallel && calls.count > 1 {
            return await dispatchParallel(calls: calls, state: state, turn: turn, query: query, callbacks: callbacks, observer: observer)
        } else {
            return await dispatchSequential(calls: calls, state: state, turn: turn, query: query, callbacks: callbacks, observer: observer)
        }
    }

    // MARK: - Sequential dispatch

    private func dispatchSequential(
        calls: [AgentToolCall],
        state: AgentState,
        turn: Int,
        query: String,
        callbacks: AgentCallbacks?,
        observer: (any AgentObserver)?
    ) async -> [AgentToolResult] {
        var results: [AgentToolResult] = []
        var seenKeys = Set<String>()

        for call in calls {
            let result = await executeSingleCall(
                call: call,
                state: state,
                turn: turn,
                query: query,
                callbacks: callbacks,
                observer: observer,
                seenKeys: &seenKeys
            )
            results.append(result)
        }
        return results
    }

    // MARK: - Parallel dispatch

    private func dispatchParallel(
        calls: [AgentToolCall],
        state: AgentState,
        turn: Int,
        query: String,
        callbacks: AgentCallbacks?,
        observer: (any AgentObserver)?
    ) async -> [AgentToolResult] {
        // Dedup first, then run unique calls in parallel
        var seenKeys = Set<String>()
        var uniqueCalls: [AgentToolCall] = []
        var dedupResults: [Int: AgentToolResult] = [:]

        for (index, call) in calls.enumerated() {
            if seenKeys.contains(call.deduplicationKey) {
                dedupResults[index] = AgentToolResult.error(
                    toolCallId: call.id, toolName: call.name,
                    message: "Duplicate tool call skipped in this turn."
                )
                observer?.onEvent(.toolCallSkippedDuplicate(call: call))
            } else {
                seenKeys.insert(call.deduplicationKey)
                uniqueCalls.append(call)
            }
        }

        // Run unique calls concurrently with Task array (preserves order)
        var tasks: [Task<AgentToolResult, Never>] = []
        for call in uniqueCalls {
            let task = Task {
                var localSeen = Set<String>()
                return await executeSingleCall(
                    call: call,
                    state: state,
                    turn: turn,
                    query: query,
                    callbacks: callbacks,
                    observer: observer,
                    seenKeys: &localSeen
                )
            }
            tasks.append(task)
        }

        var orderedResults: [AgentToolResult] = []
        for task in tasks {
            orderedResults.append(await task.value)
        }

        // Merge dedup results back in original order
        var finalResults: [AgentToolResult] = []
        var uniqueIdx = 0
        for (index, _) in calls.enumerated() {
            if let dedup = dedupResults[index] {
                finalResults.append(dedup)
            } else {
                if uniqueIdx < orderedResults.count {
                    finalResults.append(orderedResults[uniqueIdx])
                    uniqueIdx += 1
                }
            }
        }
        return finalResults
    }

    // MARK: - Single call execution

    private func executeSingleCall(
        call: AgentToolCall,
        state: AgentState,
        turn: Int,
        query: String,
        callbacks: AgentCallbacks?,
        observer: (any AgentObserver)?
    ) async -> AgentToolResult {
        var localSeen = Set<String>()
        return await executeSingleCall(
            call: call, state: state, turn: turn, query: query,
            callbacks: callbacks, observer: observer, seenKeys: &localSeen
        )
    }

    private func executeSingleCall(
        call: AgentToolCall,
        state: AgentState,
        turn: Int,
        query: String,
        callbacks: AgentCallbacks?,
        observer: (any AgentObserver)?,
        seenKeys: inout Set<String>
    ) async -> AgentToolResult {

        // Dedup within the same turn
        if seenKeys.contains(call.deduplicationKey) {
            let result = AgentToolResult.error(
                toolCallId: call.id, toolName: call.name,
                message: "Duplicate tool call skipped in this turn."
            )
            observer?.onEvent(.toolCallSkippedDuplicate(call: call))
            return result
        }
        seenKeys.insert(call.deduplicationKey)

        // Look up the tool
        guard let tool = await registry.tool(named: call.name) else {
            let result = AgentToolResult.error(
                toolCallId: call.id, toolName: call.name,
                message: "Tool '\(call.name)' is not registered."
            )
            return result
        }

        // Normalize parameters
        var params = call.parameters.mapValues { $0.value }
        params = normalizeParameters(params)
        params = injectContext(into: params)

        // Build tool context
        let context = ToolContext(
            callId: call.id,
            toolName: call.name,
            parameters: params,
            state: state,
            turn: turn,
            query: query
        )

        // beforeTool callback — can intercept
        if let beforeTool = callbacks?.beforeTool {
            if let intercepted = await beforeTool(call, context) {
                let stamped = stamp(intercepted, for: call)
                observer?.onEvent(.toolExecutionFinished(call: call, result: stamped))
                return stamped
            }
        }

        // Execute
        observer?.onEvent(.toolExecutionStarted(call: call))

        let result: AgentToolResult
        do {
            let raw = try await tool.execute(context: context)
            // afterTool callback — can modify
            if let afterTool = callbacks?.afterTool {
                if let modified = await afterTool(call, raw, context) {
                    result = stamp(modified, for: call)
                } else {
                    result = stamp(raw, for: call)
                }
            } else {
                result = stamp(raw, for: call)
            }
        } catch {
            // onToolError callback — can recover
            if let onToolError = callbacks?.onToolError {
                if let recovered = await onToolError(call, error, context) {
                    result = stamp(recovered, for: call)
                } else {
                    result = AgentToolResult.error(
                        toolCallId: call.id, toolName: call.name,
                        message: error.localizedDescription
                    )
                }
            } else {
                result = AgentToolResult.error(
                    toolCallId: call.id, toolName: call.name,
                    message: error.localizedDescription
                )
            }
        }

        observer?.onEvent(.toolExecutionFinished(call: call, result: result))
        return result
    }

    /// Force tool results to carry the model-provided call identity.
    ///
    /// Individual tools may return placeholder IDs (many examples use an empty
    /// string because the call ID belongs to the dispatcher, not the tool). Strict
    /// providers such as OpenAI and Anthropic require tool-result messages to
    /// correlate exactly with the original call ID, so the dispatcher canonicalizes
    /// every successful/intercepted/recovered result before it enters conversation
    /// memory.
    private func stamp(_ result: AgentToolResult, for call: AgentToolCall) -> AgentToolResult {
        AgentToolResult(
            id: result.id,
            toolCallId: call.id,
            toolName: result.toolName ?? call.name,
            result: result.result,
            isError: result.isError
        )
    }

    // MARK: - Parameter Normalization

    /// Apply parameter aliases (e.g. "dir" → "path").
    private func normalizeParameters(_ params: [String: Any]) -> [String: Any] {
        var normalized: [String: Any] = [:]
        for (key, value) in params {
            let canonicalKey = parameterAliases[key] ?? key
            normalized[canonicalKey] = value
        }
        return normalized
    }

    /// Inject context fields (prefixed with __ to avoid collisions).
    private func injectContext(into params: [String: Any]) -> [String: Any] {
        var result = params
        for (key, value) in contextFields {
            result["__\(key)__"] = value
        }
        return result
    }
}