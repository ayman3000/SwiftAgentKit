//
//  Agent.swift
//  SwiftAgentKit
//
//  The main Agent class — ties together LLMProviderKit, tools, memory, planning,
//  and the agent loop.
//
//  This is the universal agent that supports multiple agent philosophies:
//  - Single-shot: one LLM call, no loop
//  - Multi-turn chat: request/response with conversation history
//  - ReAct with tools: loop with tool calls, repair-retry, plan continuation
//  - Planner + ReAct: separate planning call, then ReAct loop
//

import Foundation
import LLMProviderKit

// MARK: - Agent Configuration

/// Configuration for an agent.
///
public struct AgentConfig: Sendable {

    /// The LLM provider to use (from LLMProviderKit).
    public var provider: any LLMProvider

    /// Model name (optional — falls back to provider's default).
    public var model: String?

    /// Temperature for LLM calls (0.0 = deterministic, 1.0 = creative).
    public var temperature: Double?

    /// Maximum tokens for the response.
    public var maxTokens: Int?

    /// Top-P sampling parameter.
    public var topP: Double?

    /// System prompt prefix (prepended to every conversation).
    public var systemPrompt: String?

    /// Maximum turns for the agent loop (0 = single-shot, no loop).
    public var maxTurns: Int

    /// Context window size for the model (in tokens).
    public var contextWindow: Int

    /// Maximum messages to keep in history.
    public var maxMessages: Int

    /// Whether to enable planning.
    public var enablePlanning: Bool

    /// Whether to enable repair-retry.
    public var enableRepairRetry: Bool

    /// Whether to enable plan continuation.
    public var enablePlanContinuation: Bool

    public init(
        provider: any LLMProvider,
        model: String? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        topP: Double? = nil,
        systemPrompt: String? = nil,
        maxTurns: Int = 20,
        contextWindow: Int = 8192,
        maxMessages: Int = 50,
        enablePlanning: Bool = false,
        enableRepairRetry: Bool = true,
        enablePlanContinuation: Bool = true
    ) {
        self.provider = provider
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.topP = topP
        self.systemPrompt = systemPrompt
        self.maxTurns = maxTurns
        self.contextWindow = contextWindow
        self.maxMessages = maxMessages
        self.enablePlanning = enablePlanning
        self.enableRepairRetry = enableRepairRetry
        self.enablePlanContinuation = enablePlanContinuation
    }
}

// MARK: - Agent

/// The universal AI agent.
///
/// This is the main entry point for SwiftAgentKit. It combines:
/// - **LLM backend**: LLMProviderKit's `LLMProvider` (Ollama, OpenAI, Gemini, Anthropic)
/// - **Tools**: `ToolRegistry` + `ToolDispatcher` for function-calling
/// - **Memory**: `Conversation` with token-aware context management
/// - **Planning**: `AgentPlanner` for plan-then-execute workflows
/// - **Observability**: `AgentObserver` for real-time event streaming
///
/// ## Agent Philosophies
///
/// The agent supports multiple philosophies via configuration:
///
/// 1. **Single-shot** (`maxTurns: 0`): One LLM call, no loop.
///
/// 2. **Multi-turn chat** (`maxTurns: 1`, no tools): Request/response with history.
///
/// 3. **ReAct with tools** (`maxTurns > 0`, with tools): The loop calls the LLM,
///    executes tool calls, feeds results back, repeats until done or max turns.
///
/// 4. **Planner + ReAct** (`enablePlanning: true`): Separate planning LLM call,
///    then ReAct loop with plan tracking and continuation.
///
/// ## Usage
///
/// ```swift
/// import SwiftAgentKit
/// import LLMProviderKit
/// import LLMProviderKitOllama
///
/// // 1. Create a provider
/// let provider = OllamaProvider(configuration: .local(model: "llama3.2"))
///
/// // 2. Configure the agent
/// let config = AgentConfig(
///     provider: provider,
///     systemPrompt: "You are a helpful assistant.",
///     maxTurns: 10
/// )
///
/// // 3. Create the agent
/// let agent = Agent(config: config)
///
/// // 4. Register tools
/// agent.register(ReadFileTool())
/// agent.register(WriteFileTool())
///
/// // 5. Run
/// let response = try await agent.run("Read the file at /tmp/test.txt and summarize it")
/// print(response)
/// ```
///
public final class Agent: @unchecked Sendable {

    // MARK: - Properties

    public var config: AgentConfig

    /// Tool registry (thread-safe).
    public let tools: ToolRegistry

    /// Tool dispatcher (thread-safe).
    public let dispatcher: ToolDispatcher

    /// Conversation memory.
    public let conversation: Conversation

    /// Agent state — cross-turn mutable key-value store.
    public let state: AgentState

    /// Skill registry for progressive disclosure (optional).
    public let skillRegistry: SkillRegistry

    /// Lifecycle callbacks (intercept-able).
    public var callbacks: AgentCallbacks?

    /// Planner (optional).
    public var planner: (any AgentPlanner)?

    /// Repair-retry policy.
    public var repairRetryPolicy: RepairRetryPolicy

    /// Plan continuation policy.
    public var planContinuationPolicy: PlanContinuationPolicy

    /// Observers.
    private var observers: [any AgentObserver] = []
    private let observersLock = NSLock()

    /// Fire-and-forget registration tasks created by the synchronous public API.
    /// `run(_:)` awaits these before reading registries so tool/skill registration
    /// cannot race with the first model request.
    private var pendingRegistrationTasks: [Task<Void, Never>] = []
    private let pendingRegistrationTasksQueue = DispatchQueue(label: "SwiftAgentKit.Agent.pendingRegistrationTasks")

    /// Logger.
    public var logger: AgentLogger

    /// Cancellation flag.
    private let cancellationLock = NSLock()
    private var _isCancelled = false

    // MARK: - Init

    public init(config: AgentConfig) {
        self.config = config
        self.tools = ToolRegistry()
        self.dispatcher = ToolDispatcher(registry: tools)
        self.conversation = Conversation(
            contextWindow: config.contextWindow,
            maxMessages: config.maxMessages
        )
        self.state = AgentState()
        self.skillRegistry = SkillRegistry()
        self.repairRetryPolicy = RepairRetryPolicy()
        self.planContinuationPolicy = PlanContinuationPolicy()
        self.logger = AgentLogger()

        // Set up system prompt if provided
        if let systemPrompt = config.systemPrompt {
            conversation.setSystemMessage(.system(systemPrompt))
        }

        // Set up planner if enabled
        if config.enablePlanning {
            self.planner = LLMPlanner(provider: config.provider, model: config.model)
        }
    }

    // MARK: - Tools

    /// Register a tool.
    public func register(_ tool: any AgentTool) {
        trackRegistrationTask(Task { await tools.register(tool) })
    }

    /// Register multiple tools.
    public func registerAll(_ toolsToRegister: [any AgentTool]) {
        trackRegistrationTask(Task { await tools.registerAll(toolsToRegister) })
    }

    /// Set context fields for tools (e.g. current directory, selected files).
    public func setToolContext(_ context: [String: Any]) {
        trackRegistrationTask(Task { await dispatcher.setContext(context) })
    }

    /// Register a skill for progressive disclosure.
    public func registerSkill(_ skill: AgentSkill) {
        trackRegistrationTask(Task { await skillRegistry.register(skill) })
    }

    /// Register multiple skills.
    public func registerSkills(_ skills: [AgentSkill]) {
        trackRegistrationTask(Task { await skillRegistry.registerAll(skills) })
    }

    private func trackRegistrationTask(_ task: Task<Void, Never>) {
        pendingRegistrationTasksQueue.sync {
            pendingRegistrationTasks.append(task)
        }
    }

    private func awaitPendingRegistrations() async {
        let tasks = pendingRegistrationTasksQueue.sync { () -> [Task<Void, Never>] in
            let tasks = pendingRegistrationTasks
            pendingRegistrationTasks.removeAll()
            return tasks
        }

        for task in tasks {
            await task.value
        }
    }

    // MARK: - Observers

    /// Add an observer for agent events.
    public func addObserver(_ observer: any AgentObserver) {
        observersLock.lock()
        defer { observersLock.unlock() }
        observers.append(observer)
    }

    /// Add a block-based observer.
    public func onEvent(_ block: @Sendable @escaping (AgentEvent) -> Void) {
        addObserver(BlockObserver(block))
    }

    private func emit(_ event: AgentEvent) {
        observersLock.lock()
        let snapshot = observers
        observersLock.unlock()
        for observer in snapshot {
            observer.onEvent(event)
        }
    }

    // MARK: - Cancellation

    /// Cancel the current agent run.
    public func cancel() {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        _isCancelled = true
    }

    /// Check if cancelled.
    public var isCancelled: Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return _isCancelled
    }

    private func resetCancellation() {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        _isCancelled = false
    }

    // MARK: - Run

    /// Run the agent on a query.
    ///
    /// This is the main entry point. The agent will:
    /// 1. (Optionally) Generate a plan
    /// 2. Enter the ReAct loop (if tools are registered and maxTurns > 0)
    /// 3. Return the final response
    ///
    public func run(_ query: String) async throws -> String {
        await awaitPendingRegistrations()
        resetCancellation()
        let startTime = Date()
        emit(.started(query: query))

        // beforeAgent callback — can intercept the entire run
        if let beforeAgent = callbacks?.beforeAgent {
            if let intercepted = await beforeAgent(query, state) {
                emit(.finished(summary: AgentRunSummary(
                    query: query, totalTurns: 0, toolsExecuted: 0,
                    toolErrors: 0, planStepsTotal: 0, planStepsCompleted: 0,
                    finalResponse: intercepted, elapsed: 0
                )))
                return intercepted
            }
        }

        // Add user message to conversation
        conversation.append(.user(query))

        // Get registered tools and strengthen system prompt (must happen before skill injection)
        let registeredToolsEarly = await tools.allTools()
        var effectiveSystemPrompt = config.systemPrompt ?? ""
        if !registeredToolsEarly.isEmpty {
            let toolNames = registeredToolsEarly.map { $0.name }.joined(separator: ", ")
            let toolInstruction = """

            You have access to the following tools: \(toolNames).
            IMPORTANT: When the user's request requires action (reading files, running commands, searching, creating, etc.), you MUST use the available tools instead of answering from memory. Call the appropriate tool to get real information, then use the tool results to formulate your answer. Do not guess or hallucinate results — always call the tool to get the actual data.
            """
            effectiveSystemPrompt += toolInstruction
        }

        // Progressive disclosure: inject matching skills into system prompt
        let skillAugmentation = await skillRegistry.systemPromptAugmentation(for: query)
        if !skillAugmentation.isEmpty || !effectiveSystemPrompt.isEmpty {
            // Build dynamic system message: base prompt + matching skills
            let augmentedSystem = effectiveSystemPrompt + "\n" + skillAugmentation
            conversation.setSystemMessage(.system(augmentedSystem))

            // Emit skill activation event
            let matchedNames = await skillRegistry.matchingSkills(for: query).map { $0.name }
            emit(.skillsActivated(names: matchedNames))
        }

        var totalTurns = 0
        var toolsExecuted = 0
        var toolErrors = 0
        var plan: AgentPlan?
        var repairAttempts = 0
        var planContinuationAttempts = 0

        // 1. Planning phase (optional)
        if let planner, planner.shouldPlan(for: query) {
            emit(.planningStarted)
            do {
                plan = try await planner.generatePlan(for: query, systemPrompt: nil)
                emit(.planGenerated(steps: plan!.steps.map(\.step)))

                // Add plan-progress message
                let planText = plan!.steps.enumerated().map { idx, step in
                    "\(idx + 1). \(step.step) [pending]"
                }.joined(separator: "\n")
                conversation.append(.user("Execution Plan:\n\(planText)\n\nExecute these steps one by one using available tools."))
            } catch {
                logger.warning("Planning failed: \(error)")
            }
        }

        // 2. Get registered tools (already fetched early for system prompt)
        let registeredTools = registeredToolsEarly

        // Convert tool definitions to LLMProviderKit format
        let llmToolDefs = registeredTools.map { tool -> LLMToolDefinition in
            let paramsData = try? JSONEncoder().encode(tool.parameters)
            let paramsDict = paramsData.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
            return LLMToolDefinition(name: tool.name, description: tool.description, parameters: paramsDict)
        }

        // 3. Agent loop
        if config.maxTurns > 0 && !registeredTools.isEmpty {
            // ReAct loop with tools
            while totalTurns < config.maxTurns {
                if isCancelled {
                    emit(.cancelled)
                    throw AgentError.cancelled
                }
                totalTurns += 1

                // Get messages for LLM call (trimmed to context window)
                let messagesForLLM = conversation.messagesForLLMCall()
                let removedCount = conversation.allMessages().count - messagesForLLM.count
                if removedCount > 0 {
                    emit(.historyTrimmed(removedCount: removedCount, remainingCount: messagesForLLM.count))
                }

                emit(.llmCallStarted(turn: totalTurns))

                // beforeModel callback — can skip the LLM call
                if let beforeModel = callbacks?.beforeModel {
                    if let intercepted = await beforeModel(messagesForLLM, state) {
                        emit(.llmCallCompleted(turn: totalTurns, response: intercepted))
                        // Treat as if the model returned this response
                        if intercepted.hasToolCalls, let toolCalls = intercepted.toolCalls {
                            emit(.toolCallsReceived(toolCalls))
                            conversation.append(.assistant(content: intercepted.text, toolCalls: toolCalls))
                            let dispatcherObserver = BlockObserver { [weak self] event in
                                self?.emit(event)
                            }
                            let results = await dispatcher.dispatch(
                                calls: toolCalls, state: state,
                                turn: totalTurns, query: query,
                                callbacks: callbacks, observer: dispatcherObserver
                            )
                            toolsExecuted += results.count
                            toolErrors += results.filter(\.isError).count
                            lastTurnErrors = results.filter(\.isError)
                            conversation.append(.tool(results: results))
                            _ = conversation.trim()
                            continue
                        }
                        conversation.append(.assistant(intercepted.text))
                        let summary = AgentRunSummary(
                            query: query, totalTurns: totalTurns, toolsExecuted: toolsExecuted,
                            toolErrors: toolErrors, planStepsTotal: plan?.steps.count ?? 0,
                            planStepsCompleted: plan?.completedCount ?? 0,
                            finalResponse: intercepted.text, elapsed: Date().timeIntervalSince(startTime)
                        )
                        emit(.finished(summary: summary))
                        return intercepted.text
                    }
                }

                // Build LLM request (with state-templated system prompt)
                let llmMessages = messagesForLLM.flatMap { msg -> [LLMMessage] in
                    if msg.role == .system {
                        return [.system(state.template(msg.content))]
                    }
                    return msg.toLLMMessages()
                }
                let request = LLMRequest(
                    model: config.model ?? config.provider.configuration.defaultModel ?? "",
                    messages: llmMessages,
                    temperature: config.temperature,
                    maxTokens: config.maxTokens,
                    topP: config.topP,
                    tools: llmToolDefs
                )

                // Call the provider
                let response: LLMResponse
                do {
                    response = try await config.provider.complete(request)
                } catch {
                    // onModelError callback — can provide fallback
                    if let onModelError = callbacks?.onModelError {
                        if let fallback = await onModelError(error, state) {
                            emit(.llmCallCompleted(turn: totalTurns, response: fallback))
                            conversation.append(.assistant(fallback.text))
                            let summary = AgentRunSummary(
                                query: query, totalTurns: totalTurns, toolsExecuted: toolsExecuted,
                                toolErrors: toolErrors, planStepsTotal: plan?.steps.count ?? 0,
                                planStepsCompleted: plan?.completedCount ?? 0,
                                finalResponse: fallback.text, elapsed: Date().timeIntervalSince(startTime)
                            )
                            emit(.finished(summary: summary))
                            return fallback.text
                        }
                    }
                    emit(.llmCallRetrying(turn: totalTurns, attempt: 1, error: error.localizedDescription))
                    throw AgentError.providerError(error.localizedDescription)
                }

                // Parse the response
                var agentResponse = AgentLLMResponse.from(response)

                // afterModel callback — can modify the response
                if let afterModel = callbacks?.afterModel {
                    if let modified = await afterModel(agentResponse, state) {
                        agentResponse = modified
                    }
                }

                emit(.llmCallCompleted(turn: totalTurns, response: agentResponse))

                // Check for tool calls
                guard agentResponse.hasToolCalls, let toolCalls = agentResponse.toolCalls else {
                    // No tool calls — model is done (or needs nudging)

                    // Repair-retry check
                    if config.enableRepairRetry {
                        let lastErrors = lastTurnErrors
                        if repairRetryPolicy.shouldRetry(
                            repairableErrors: lastErrors,
                            attemptsUsed: repairAttempts,
                            turnsRemaining: config.maxTurns - totalTurns
                        ) {
                            conversation.append(.assistant(agentResponse.text))
                            let nudge = repairRetryPolicy.nudge(for: lastErrors)
                            conversation.append(.user(nudge))
                            repairAttempts += 1
                            emit(.repairRetryTriggered(errors: lastErrors, attempt: repairAttempts))
                            continue
                        }
                    }

                    // Plan continuation check
                    if config.enablePlanContinuation, let plan, planContinuationPolicy.shouldContinue(
                        plan: plan,
                        attemptsUsed: planContinuationAttempts,
                        turnsRemaining: config.maxTurns - totalTurns
                    ) {
                        conversation.append(.assistant(agentResponse.text))
                        let nudge = planContinuationPolicy.nudge(for: plan)
                        conversation.append(.user(nudge))
                        planContinuationAttempts += 1
                        emit(.planContinuationTriggered(pendingSteps: plan.pendingSteps.map(\.step), attempt: planContinuationAttempts))
                        continue
                    }

                    // Done — return the response
                    conversation.append(.assistant(agentResponse.text))
                    lastTurnErrors = []

                    let summary = AgentRunSummary(
                        query: query,
                        totalTurns: totalTurns,
                        toolsExecuted: toolsExecuted,
                        toolErrors: toolErrors,
                        planStepsTotal: plan?.steps.count ?? 0,
                        planStepsCompleted: plan?.completedCount ?? 0,
                        finalResponse: agentResponse.text,
                        elapsed: Date().timeIntervalSince(startTime)
                    )
                    emit(.finished(summary: summary))

                    // afterAgent callback — can modify the final response
                    if let afterAgent = callbacks?.afterAgent {
                        if let modified = await afterAgent(agentResponse.text, state) {
                            state.clearTemp()
                            return modified
                        }
                    }
                    state.clearTemp()
                    return agentResponse.text
                }

                // Has tool calls — execute them
                emit(.toolCallsReceived(toolCalls))
                conversation.append(.assistant(content: agentResponse.text, toolCalls: toolCalls))

                // Dispatch tool calls (with state + callbacks, parallel by default)
                let dispatcherObserver = BlockObserver { [weak self] event in
                    self?.emit(event)
                }
                let results = await dispatcher.dispatch(
                    calls: toolCalls,
                    state: state,
                    turn: totalTurns,
                    query: query,
                    callbacks: callbacks,
                    parallel: true,
                    observer: dispatcherObserver
                )
                toolsExecuted += results.count
                toolErrors += results.filter(\.isError).count
                lastTurnErrors = results.filter(\.isError)

                // Update plan progress
                if let planner, var p = plan {
                    for result in results {
                        for call in toolCalls where call.id == result.toolCallId {
                            planner.updateProgress(plan: &p, toolCall: call, result: result)
                            emit(.planStepUpdated(
                                index: p.steps.firstIndex(where: { $0.status == .completed }) ?? 0,
                                step: "",
                                status: .completed
                            ))
                        }
                    }
                    plan = p
                }

                // Add tool results to conversation
                conversation.append(.tool(results: results))

                // Trim conversation
                _ = conversation.trim()
            }

            // Max turns reached
            let summary = AgentRunSummary(
                query: query,
                totalTurns: totalTurns,
                toolsExecuted: toolsExecuted,
                toolErrors: toolErrors,
                planStepsTotal: plan?.steps.count ?? 0,
                planStepsCompleted: plan?.completedCount ?? 0,
                finalResponse: "Max turns reached without completion.",
                elapsed: Date().timeIntervalSince(startTime)
            )
            emit(.finished(summary: summary))
            throw AgentError.maxTurnsReached(config.maxTurns)

        } else {
            // Single-shot or multi-turn chat (no tools)
            let messagesForLLM = conversation.messagesForLLMCall()
            let llmMessages = messagesForLLM.flatMap { msg -> [LLMMessage] in
                if msg.role == .system {
                    return [.system(state.template(msg.content))]
                }
                return msg.toLLMMessages()
            }
            let request = LLMRequest(
                model: config.model ?? config.provider.configuration.defaultModel ?? "",
                messages: llmMessages,
                temperature: config.temperature,
                maxTokens: config.maxTokens,
                topP: config.topP
            )

            emit(.llmCallStarted(turn: 1))

            // beforeModel callback
            if let beforeModel = callbacks?.beforeModel {
                if let intercepted = await beforeModel(messagesForLLM, state) {
                    emit(.llmCallCompleted(turn: 1, response: intercepted))
                    conversation.append(.assistant(intercepted.text))
                    state.clearTemp()
                    let summary = AgentRunSummary(
                        query: query, totalTurns: 1, toolsExecuted: 0,
                        toolErrors: 0, planStepsTotal: plan?.steps.count ?? 0,
                        planStepsCompleted: plan?.completedCount ?? 0,
                        finalResponse: intercepted.text, elapsed: Date().timeIntervalSince(startTime)
                    )
                    emit(.finished(summary: summary))

                    // afterAgent callback
                    if let afterAgent = callbacks?.afterAgent {
                        if let modified = await afterAgent(intercepted.text, state) {
                            return modified
                        }
                    }
                    return intercepted.text
                }
            }

            let response: LLMResponse
            do {
                response = try await config.provider.complete(request)
            } catch {
                if let onModelError = callbacks?.onModelError {
                    if let fallback = await onModelError(error, state) {
                        emit(.llmCallCompleted(turn: 1, response: fallback))
                        conversation.append(.assistant(fallback.text))
                        state.clearTemp()
                        emit(.finished(summary: AgentRunSummary(
                            query: query, totalTurns: 1, toolsExecuted: 0,
                            toolErrors: 0, planStepsTotal: plan?.steps.count ?? 0,
                            planStepsCompleted: plan?.completedCount ?? 0,
                            finalResponse: fallback.text, elapsed: Date().timeIntervalSince(startTime)
                        )))
                        return fallback.text
                    }
                }
                throw AgentError.providerError(error.localizedDescription)
            }

            var agentResponse = AgentLLMResponse.from(response)

            // afterModel callback
            if let afterModel = callbacks?.afterModel {
                if let modified = await afterModel(agentResponse, state) {
                    agentResponse = modified
                }
            }

            emit(.llmCallCompleted(turn: 1, response: agentResponse))

            conversation.append(.assistant(agentResponse.text))
            state.clearTemp()

            let summary = AgentRunSummary(
                query: query,
                totalTurns: 1,
                toolsExecuted: 0,
                toolErrors: 0,
                planStepsTotal: plan?.steps.count ?? 0,
                planStepsCompleted: plan?.completedCount ?? 0,
                finalResponse: agentResponse.text,
                elapsed: Date().timeIntervalSince(startTime)
            )
            emit(.finished(summary: summary))

            // afterAgent callback — can modify the final response
            if let afterAgent = callbacks?.afterAgent {
                if let modified = await afterAgent(agentResponse.text, state) {
                    return modified
                }
            }

            return agentResponse.text
        }
    }

    /// Track errors from the last turn (for repair-retry).
    private var lastTurnErrors: [AgentToolResult] = []

    // MARK: - Streaming

    /// Run the agent in streaming mode (for simple queries without tools).
    ///
    /// Returns an `AsyncThrowingStream` of text chunks.
    /// Note: the agent loop itself is non-streaming by design (needs complete
    /// responses for tool calls). Streaming is for the simple-query path.
    ///
    public func stream(_ query: String) -> AsyncThrowingStream<String, Error> {
        let provider = config.provider
        let model = config.model ?? config.provider.configuration.defaultModel ?? ""
        let temperature = config.temperature
        let maxTokens = config.maxTokens
        let topP = config.topP

        conversation.append(.user(query))
        let messagesForLLM = conversation.messagesForLLMCall()
        let llmMessages = messagesForLLM.flatMap { msg -> [LLMMessage] in
            if msg.role == .system {
                return [.system(state.template(msg.content))]
            }
            return msg.toLLMMessages()
        }

        let request = LLMRequest(
            model: model,
            messages: llmMessages,
            temperature: temperature,
            maxTokens: maxTokens,
            topP: topP
        )

        return AsyncThrowingStream { [weak self] continuation in
            Task { [weak self] in
                do {
                    let stream = provider.stream(request)
                    var fullText = ""
                    for try await chunk in stream {
                        switch chunk {
                        case .text(let text):
                            fullText += text
                            continuation.yield(text)
                            self?.emit(.streamChunk(text))
                        case .finish:
                            self?.emit(.streamFinished)
                        case .error(let error):
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                    self?.conversation.append(.assistant(fullText))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Run the agent loop with tools, then stream the final response.
    ///
    /// This runs the full ReAct loop (non-streaming, as it needs complete
    /// responses for tool calls). Once the model stops calling tools and
    /// produces its final summary, that summary is streamed token-by-token.
    ///
    /// If no tools are registered, this is equivalent to `stream()`.
    ///
    public func runStreaming(_ query: String) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { [weak self] continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                // Check if we have tools — if not, just stream
                let registeredTools = await self.tools.allTools()
                if registeredTools.isEmpty || self.config.maxTurns <= 0 {
                    // No tools — use regular streaming
                    for try await chunk in self.stream(query) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                    return
                }

                // Phase 1: Run the tool loop (non-streaming) until model stops calling tools
                // We reuse the run() logic but need to intercept the final response for streaming
                // The simplest approach: run() returns the final text, then we yield it.
                // For true streaming of the final response, we'd need to modify the loop.
                // For now, yield the final text as a single chunk.
                do {
                    let result = try await self.run(query)
                    continuation.yield(result)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Structured Output

    /// Run the agent and parse the response as structured JSON.
    ///
    /// Uses `StructuredOutput<T>` to extract JSON from the model's response,
    /// handling markdown fences and surrounding prose.
    ///
    public func runStructured<T: Decodable>(_ query: String, as type: T.Type) async throws -> T {
        let response = try await run(query)
        return try StructuredOutput<T>.parse(from: response)
    }
}