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

    /// Tools to register at agent init time.
    /// Convenience — equivalent to calling `agent.registerAll(tools)` after init.
    public var tools: [any AgentTool]

    /// Opt-in ContextSift-style context management. When set, completed tool
    /// exchanges are moved out of active model context (replaced by a receipt
    /// ledger, full output preserved in the manager's `ArtifactStore` and
    /// retrievable via `artifact_read` / `artifact_search`). When `nil`, the
    /// agent uses its normal trim-based context handling.
    public var contextManager: ContextManager?

    /// When `true`, tools marked `requiresConfirmation` run WITHOUT prompting via
    /// `AgentCallbacks.onToolConfirmation` — the agent has full autonomy. Default
    /// `false` (confirmation-gated). Can also be flipped at runtime with
    /// `agent.setAutonomousMode(_:)`.
    public var autonomousMode: Bool

    /// When `true`, the agent auto-registers the `delegate_task` tool so the
    /// model can spawn sub-agents: child agents with the parent's tools (minus
    /// delegation/memory/skill writes), a fresh context, and inherited
    /// confirmation gating. One level deep — children cannot delegate further.
    /// Read at construction time — flipping it after init has no effect.
    public var enableSubAgents: Bool

    /// Max times an unsatisfied `AgentCallbacks.verifyCompletion` verdict may
    /// re-nudge the model to keep working before the agent stops anyway. Bounds
    /// goal-driven looping (also bounded by `maxTurns`). Default 3.
    public var maxVerificationRetries: Int

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
        enablePlanContinuation: Bool = true,
        tools: [any AgentTool] = [],
        contextManager: ContextManager? = nil,
        autonomousMode: Bool = false,
        enableSubAgents: Bool = false,
        maxVerificationRetries: Int = 3
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
        self.tools = tools
        self.contextManager = contextManager
        self.autonomousMode = autonomousMode
        self.enableSubAgents = enableSubAgents
        self.maxVerificationRetries = maxVerificationRetries
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

    /// Optional persistent memory store. When set, the agent auto-registers
    /// `RememberTool` and injects the memory context block into the system prompt.
    public var memoryStore: (any AgentMemoryStore)? {
        didSet {
            if let store = memoryStore {
                register(RememberTool(store: store))
            }
        }
    }

    /// Optional persistent goal store. When set, `run(_:trackGoal:)` persists goal
    /// progress and results.
    public var goalStore: (any AgentGoalStore)?

    /// Skill registry for progressive disclosure (optional).
    public let skillRegistry: SkillRegistry

    /// Spawner for sub-agents; non-nil when `config.enableSubAgents` is on.
    public private(set) var subAgentSpawner: SubAgentSpawner?

    /// Optional persistent skill store. When set, the agent loads previously
    /// authored skills into `skillRegistry` and auto-registers `LearnSkillTool`,
    /// so it can turn recurring tasks (or corrected mistakes) into reusable,
    /// keyword-triggered skills that persist across sessions.
    public var skillStore: (any AgentSkillStore)? {
        didSet {
            guard let store = skillStore else { return }
            register(LearnSkillTool(store: store, registry: skillRegistry))
            trackRegistrationTask(Task { [skillRegistry] in
                if let skills = try? await store.loadAll() {
                    await skillRegistry.registerAll(skills)
                }
            })
        }
    }

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

    /// Estimated token count of the most recent prompt actually sent to the model
    /// (after context management / trimming) — i.e. what the model really saw, not
    /// the full stored history. Useful for a context-usage indicator.
    public var lastPromptTokens: Int {
        promptTokensLock.lock(); defer { promptTokensLock.unlock() }
        return _lastPromptTokens
    }
    private let promptTokensLock = NSLock()
    private var _lastPromptTokens = 0

    /// Cancellation flag.
    private let cancellationLock = NSLock()
    private var _isCancelled = false

    /// Guards mutable per-run state and conversation writes from overlapping `run(_:)` calls.
    private let runLock = NSLock()
    private var _isRunActive = false

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

        // Auto-register tools passed via config
        if !config.tools.isEmpty {
            for tool in config.tools {
                register(tool)
            }
        }

        // Register the context manager's artifact-retrieval tools so the model
        // can pull full tool outputs back from external storage on demand.
        if let contextManager = config.contextManager {
            for tool in contextManager.artifactTools {
                register(tool)
            }
        }

        // Apply autonomous mode (skips the confirmation gate) if configured.
        if config.autonomousMode {
            setAutonomousMode(true)
        }

        // Sub-agents: register the delegation tool. The spawner strips this
        // tool (and sets enableSubAgents=false) on children, so delegation is
        // one level deep.
        if config.enableSubAgents {
            let spawner = SubAgentSpawner(parent: self)
            self.subAgentSpawner = spawner
            register(DelegateTaskTool(spawner: spawner, emit: { [weak self] event in
                self?.emitEvent(event)
            }))
        }
    }

    // MARK: - Tools

    /// Enable/disable autonomous mode at runtime. When `true`, tools marked
    /// `requiresConfirmation` run without prompting `onToolConfirmation`.
    public func setAutonomousMode(_ enabled: Bool) {
        trackRegistrationTask(Task { await dispatcher.setAutonomousMode(enabled) })
    }

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
        // Swift 6: [String: Any] is not Sendable — wrap in @unchecked Sendable box
        let box = ToolContextBox(values: context)
        trackRegistrationTask(Task { await dispatcher.setContext(box.values) })
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

    /// Flush any pending fire-and-forget tool/skill registrations that were
    /// enqueued synchronously (e.g. via `register(_:)` or `AgentConfig.tools`).
    ///
    /// Module-internal machinery: called by `SubAgentSpawner.makeChild()` when
    /// snapshotting the parent's tool list, and by `run(_:)` before the first
    /// model call. Not public API.
    func flushRegistrations() async {
        await awaitPendingRegistrations()
    }

    // MARK: - Observers

    /// Add an observer for agent events.
    public func addObserver(_ observer: any AgentObserver) {
        observersLock.lock()
        defer { observersLock.unlock() }
        observers.append(observer)
    }

    /// Remove a previously-added observer (matched by identity).
    ///
    /// Long-lived agents outlive the views that observe them; callers must
    /// remove their observer when torn down, otherwise observers accumulate and
    /// each event is delivered multiple times.
    public func removeObserver(_ observer: any AgentObserver) {
        observersLock.lock()
        defer { observersLock.unlock() }
        observers.removeAll { $0 === observer }
    }

    /// Add a block-based observer, returning the observer token so it can later
    /// be passed to `removeObserver(_:)`.
    @discardableResult
    public func onEvent(_ block: @Sendable @escaping (AgentEvent) -> Void) -> any AgentObserver {
        let observer = BlockObserver(block)
        addObserver(observer)
        return observer
    }

    private func emit(_ event: AgentEvent) {
        observersLock.lock()
        let snapshot = observers
        observersLock.unlock()
        for observer in snapshot {
            observer.onEvent(event)
        }
    }

    /// Internal event entry point for sub-agent machinery (forwards to observers).
    func emitEvent(_ event: AgentEvent) {
        emit(event)
    }

    // MARK: - Cancellation

    /// Cancel the current agent run (and any live sub-agents).
    public func cancel() {
        cancellationLock.lock()
        _isCancelled = true
        cancellationLock.unlock()
        subAgentSpawner?.cancelAll()
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
        subAgentSpawner?.resetCancellation()
    }

    private func beginRunIfIdle() -> Bool {
        runLock.lock()
        defer { runLock.unlock() }
        guard !_isRunActive else { return false }
        _isRunActive = true
        return true
    }

    private func endRun() {
        runLock.lock()
        _isRunActive = false
        runLock.unlock()
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
        try await run(query, images: [])
    }

    /// Run the agent with a user query and optional images (for vision-capable models).
    ///
    /// Images are forwarded to the provider as base64-encoded attachments in the user message.
    /// Works with models that support vision (e.g., GPT-4o, Gemini, LLaVA).
    ///
    public func run(_ query: String, images: [LLMImage]) async throws -> String {
        try await runLoop(query: query, images: images, onText: nil)
    }

    /// Shared ReAct implementation backing both `run(_:)` (non-streaming) and
    /// `runStreaming(_:)` (streaming). When `onText` is non-nil, each turn is
    /// streamed and assistant text deltas are delivered to `onText` as they
    /// arrive — including the final answer, token-by-token.
    private func runLoop(query: String, images: [LLMImage], onText: (@Sendable (String) -> Void)?) async throws -> String {
        guard beginRunIfIdle() else {
            throw AgentError.runInProgress
        }
        defer { endRun() }

        await awaitPendingRegistrations()
        resetCancellation()
        let startTime = Date()
        emit(.started(query: query))

        // beforeAgent callback — can intercept the entire run
        if let beforeAgent = callbacks?.beforeAgent {
            if let intercepted = await beforeAgent(query, state) {
                emit(.finished(summary: makeRunSummary(
                    query: query,
                    totalTurns: 0,
                    toolsExecuted: 0,
                    toolErrors: 0,
                    plan: nil,
                    finalResponse: intercepted,
                    startTime: startTime,
                    elapsedOverride: 0
                )))
                return intercepted
            }
        }

        // Add user message to conversation
        if images.isEmpty {
            conversation.append(.user(query))
        } else {
            conversation.append(.user(query, images: images))
        }

        // Get registered tools and strengthen system prompt (must happen before skill injection)
        let registeredToolsEarly = await tools.allTools()
        var effectiveSystemPrompt = config.systemPrompt ?? ""

        // Persistent memory must be part of every model call. Loading it at run
        // time ensures facts saved by earlier runs are immediately available.
        if let memoryStore {
            let memoryContext = await memoryStore.loadContextBlock()
            if !memoryContext.isEmpty {
                if !effectiveSystemPrompt.isEmpty {
                    effectiveSystemPrompt += "\n\n"
                }
                effectiveSystemPrompt += memoryContext
            }
        }

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
        var verificationAttempts = 0

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
        let llmToolDefs = makeLLMToolDefinitions(from: registeredTools)

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
                            let results = await dispatchToolCalls(toolCalls, turn: totalTurns, query: query)
                            toolsExecuted += results.count
                            toolErrors += results.filter(\.isError).count
                            lastTurnErrors = results.filter(\.isError)
                            conversation.append(.tool(results: results))
                            _ = conversation.trim()
                            continue
                        }
                        onText?(intercepted.text)
                        conversation.append(.assistant(intercepted.text))
                        let summary = makeRunSummary(
                            query: query,
                            totalTurns: totalTurns,
                            toolsExecuted: toolsExecuted,
                            toolErrors: toolErrors,
                            plan: plan,
                            finalResponse: intercepted.text,
                            startTime: startTime
                        )
                        emit(.finished(summary: summary))
                        return intercepted.text
                    }
                }

                // Build LLM request (with state-templated system prompt)
                let request = await makeLLMRequest(messagesForLLM: messagesForLLM, tools: llmToolDefs)

                // Call the provider (streamed when onText is set)
                var agentResponse: AgentLLMResponse
                do {
                    agentResponse = try await executeTurn(request: request, onText: onText)
                } catch {
                    // onModelError callback — can provide fallback
                    if let onModelError = callbacks?.onModelError {
                        if let fallback = await onModelError(error, state) {
                            emit(.llmCallCompleted(turn: totalTurns, response: fallback))
                            conversation.append(.assistant(fallback.text))
                            let summary = makeRunSummary(
                                query: query,
                                totalTurns: totalTurns,
                                toolsExecuted: toolsExecuted,
                                toolErrors: toolErrors,
                                plan: plan,
                                finalResponse: fallback.text,
                                startTime: startTime
                            )
                            emit(.finished(summary: summary))
                            return fallback.text
                        }
                    }
                    emit(.llmCallRetrying(turn: totalTurns, attempt: 1, error: error.localizedDescription))
                    throw AgentError.providerError(error.localizedDescription)
                }

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

                    // Goal-completion verification — don't trust the model's "done"
                    // signal; verify the goal is actually met before stopping.
                    if let verify = callbacks?.verifyCompletion, verificationAttempts < config.maxVerificationRetries {
                        let verdict = await verify(query, agentResponse.text, state)
                        switch verdict {
                        case .satisfied:
                            break  // fall through to Done
                        case .unsatisfied(let reason):
                            conversation.append(.assistant(agentResponse.text))
                            conversation.append(.user(
                                "The task is NOT complete yet. \(reason)\n\nKeep going until it is fully done."))
                            verificationAttempts += 1
                            emit(.completionVerificationFailed(reason: reason, attempt: verificationAttempts))
                            continue
                        case .blocked(let reason):
                            conversation.append(.assistant(agentResponse.text))
                            emit(.completionBlocked(reason: reason))
                            // Stop early: surface the blocker rather than burn turns.
                            let blockedText = agentResponse.text.isEmpty
                                ? "Blocked: \(reason)"
                                : agentResponse.text + "\n\n[blocked: \(reason)]"
                            state.clearTemp()
                            return blockedText
                        }
                    }

                    // Done — return the response
                    conversation.append(.assistant(agentResponse.text))
                    lastTurnErrors = []

                    let summary = makeRunSummary(
                        query: query,
                        totalTurns: totalTurns,
                        toolsExecuted: toolsExecuted,
                        toolErrors: toolErrors,
                        plan: plan,
                        finalResponse: agentResponse.text,
                        startTime: startTime
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
                let results = await dispatchToolCalls(toolCalls, turn: totalTurns, query: query)
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
            let summary = makeRunSummary(
                query: query,
                totalTurns: totalTurns,
                toolsExecuted: toolsExecuted,
                toolErrors: toolErrors,
                plan: plan,
                finalResponse: "Max turns reached without completion.",
                startTime: startTime
            )
            emit(.finished(summary: summary))
            throw AgentError.maxTurnsReached(config.maxTurns)

        } else {
            // Single-shot or multi-turn chat (no tools)
            let messagesForLLM = conversation.messagesForLLMCall()
            let request = await makeLLMRequest(messagesForLLM: messagesForLLM)

            emit(.llmCallStarted(turn: 1))

            // beforeModel callback
            if let beforeModel = callbacks?.beforeModel {
                if let intercepted = await beforeModel(messagesForLLM, state) {
                    emit(.llmCallCompleted(turn: 1, response: intercepted))
                    onText?(intercepted.text)
                    conversation.append(.assistant(intercepted.text))
                    state.clearTemp()
                    let summary = makeRunSummary(
                        query: query,
                        totalTurns: 1,
                        toolsExecuted: 0,
                        toolErrors: 0,
                        plan: plan,
                        finalResponse: intercepted.text,
                        startTime: startTime
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

            var agentResponse: AgentLLMResponse
            do {
                agentResponse = try await executeTurn(request: request, onText: onText)
            } catch {
                if let onModelError = callbacks?.onModelError {
                    if let fallback = await onModelError(error, state) {
                        emit(.llmCallCompleted(turn: 1, response: fallback))
                        conversation.append(.assistant(fallback.text))
                        state.clearTemp()
                        emit(.finished(summary: makeRunSummary(
                            query: query,
                            totalTurns: 1,
                            toolsExecuted: 0,
                            toolErrors: 0,
                            plan: plan,
                            finalResponse: fallback.text,
                            startTime: startTime
                        )))
                        return fallback.text
                    }
                }
                throw AgentError.providerError(error.localizedDescription)
            }

            // afterModel callback
            if let afterModel = callbacks?.afterModel {
                if let modified = await afterModel(agentResponse, state) {
                    agentResponse = modified
                }
            }

            emit(.llmCallCompleted(turn: 1, response: agentResponse))

            conversation.append(.assistant(agentResponse.text))
            state.clearTemp()

            let summary = makeRunSummary(
                query: query,
                totalTurns: 1,
                toolsExecuted: 0,
                toolErrors: 0,
                plan: plan,
                finalResponse: agentResponse.text,
                startTime: startTime
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

    private func makeRunSummary(
        query: String,
        totalTurns: Int,
        toolsExecuted: Int,
        toolErrors: Int,
        plan: AgentPlan?,
        finalResponse: String,
        startTime: Date,
        elapsedOverride: TimeInterval? = nil
    ) -> AgentRunSummary {
        AgentRunSummary(
            query: query,
            totalTurns: totalTurns,
            toolsExecuted: toolsExecuted,
            toolErrors: toolErrors,
            planStepsTotal: plan?.steps.count ?? 0,
            planStepsCompleted: plan?.completedCount ?? 0,
            finalResponse: finalResponse,
            elapsed: elapsedOverride ?? Date().timeIntervalSince(startTime)
        )
    }

    /// Execute one turn against the provider and return the parsed response.
    ///
    /// - When `onText` is `nil`, the turn is non-streaming (`complete`).
    /// - When `onText` is non-nil, the turn is streamed: text deltas are
    ///   delivered to `onText` as they arrive. If the stream signals native tool
    ///   use, the turn is re-issued non-streaming to obtain reliable tool-call
    ///   arguments (provider streaming doesn't deliver complete tool args
    ///   consistently). Otherwise the streamed text is parsed the same way as a
    ///   non-streaming response — so text-marker tool calls (for models without
    ///   native tool calling) are still detected.
    private func executeTurn(
        request: LLMRequest,
        onText: (@Sendable (String) -> Void)?
    ) async throws -> AgentLLMResponse {
        guard let onText else {
            let response = try await config.provider.complete(request)
            return AgentLLMResponse.from(response)
        }

        var streamedText = ""
        var streamedToolCalls: [LLMToolCall] = []
        var sawNativeToolSignal = false
        for try await chunk in config.provider.stream(request) {
            switch chunk {
            case .text(let text):
                streamedText += text
                onText(text)
                emit(.streamChunk(text))
            case .toolCall(let call):
                streamedToolCalls.append(call)
                sawNativeToolSignal = true
            case .finish(let reason, _):
                if reason == .toolCalls { sawNativeToolSignal = true }
            case .error(let error):
                throw error
            }
        }
        emit(.streamFinished)

        // If the stream already delivered complete tool calls (name present),
        // use them directly — no re-issue. This avoids a second, possibly
        // divergent generation for in-process providers (e.g. MLX at a non-zero
        // temperature), which could otherwise return empty/different tool calls.
        if !streamedToolCalls.isEmpty && streamedToolCalls.allSatisfy({ !$0.name.isEmpty }) {
            let response = LLMResponse(
                text: streamedText,
                finishReason: .toolCalls,
                toolCalls: streamedToolCalls,
                request: request,
                providerName: type(of: config.provider).name
            )
            return AgentLLMResponse.from(response)
        }

        if sawNativeToolSignal {
            // Signaled tool use but didn't stream usable args (e.g. an HTTP
            // provider that only flags tool use) — re-issue non-streaming.
            let response = try await config.provider.complete(request)
            let parsed = AgentLLMResponse.from(response)
            // Keep any streamed preamble text if the re-issue returned none.
            if parsed.text.isEmpty && !streamedText.isEmpty {
                return AgentLLMResponse(
                    text: streamedText,
                    toolCalls: parsed.toolCalls,
                    finishReason: parsed.finishReason,
                    usage: parsed.usage,
                    providerName: parsed.providerName
                )
            }
            return parsed
        }

        // No native tool signal — parse the streamed text so text-marker tool
        // calls are still recognized (parity with the non-streaming path).
        let synthesized = LLMResponse(
            text: streamedText,
            finishReason: .stop,
            usage: nil,
            toolCalls: [],
            request: request,
            providerName: type(of: config.provider).name
        )
        return AgentLLMResponse.from(synthesized)
    }

    private func makeLLMToolDefinitions(from registeredTools: [any AgentTool]) -> [LLMToolDefinition] {
        registeredTools.map { tool -> LLMToolDefinition in
            let paramsData = try? JSONEncoder().encode(tool.parameters)
            let paramsDict = paramsData.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
            return LLMToolDefinition(name: tool.name, description: tool.description, parameters: paramsDict)
        }
    }

    private func makeLLMRequest(
        messagesForLLM: [AgentMessage],
        tools: [LLMToolDefinition] = []
    ) async -> LLMRequest {
        let llmMessages: [LLMMessage]
        if let contextManager = config.contextManager {
            // ContextSift-style: externalize completed tool exchanges.
            llmMessages = await contextManager.modelMessages(messagesForLLM) { [state] content in
                state.template(content)
            }
        } else {
            llmMessages = messagesForLLM.flatMap { msg -> [LLMMessage] in
                if msg.role == .system {
                    return [.system(state.template(msg.content))]
                }
                return msg.toLLMMessages()
            }
        }

        // Record the size of what we actually send (post context-management), so
        // an app can show real context usage rather than raw-history size.
        let promptChars = llmMessages.reduce(0) { $0 + $1.content.count }
        let estimate = Int((Double(promptChars) / 3.5).rounded()) + llmMessages.count * 4
        promptTokensLock.withLock { _lastPromptTokens = estimate }

        return LLMRequest(
            model: config.model ?? config.provider.configuration.defaultModel ?? "",
            messages: llmMessages,
            temperature: config.temperature,
            maxTokens: config.maxTokens,
            topP: config.topP,
            tools: tools
        )
    }

    private func persistGoal(query: String, status: AgentGoalStatus, summary: String?, plan: AgentPlan?) async {
        guard let goalStore = goalStore else { return }
        let goal = AgentGoal(
            query: query,
            status: status,
            plan: plan,
            summary: summary
        )
        try? await goalStore.save(goal)
    }

    private func persistGoal(_ goal: AgentGoal) async {
        guard let goalStore = goalStore else { return }
        try? await goalStore.save(goal)
    }

    private func dispatchToolCalls(
        _ toolCalls: [AgentToolCall],
        turn: Int,
        query: String
    ) async -> [AgentToolResult] {
        let dispatcherObserver = BlockObserver { [weak self] event in
            self?.emit(event)
        }
        return await dispatcher.dispatch(
            calls: toolCalls,
            state: state,
            turn: turn,
            query: query,
            callbacks: callbacks,
            parallel: true,
            observer: dispatcherObserver
        )
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
                        case .toolCall:
                            // Tool calls during streaming — handled after full response
                            break
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

    /// Run the agent loop, streaming assistant text token-by-token.
    ///
    /// This shares the exact ReAct implementation used by `run(_:)` — including
    /// planning, skills, repair-retry, and lifecycle callbacks — but streams each
    /// turn. Any assistant text, including the final answer, reaches the caller as
    /// it is generated. Turns that signal tool use are re-issued non-streaming to
    /// obtain reliable tool-call arguments (provider streaming does not deliver
    /// complete tool arguments consistently), then tools run and the loop
    /// continues; the final tool-free turn streams its answer directly.
    ///
    /// - Note: `afterModel`/`afterAgent` callbacks can still rewrite the returned
    ///   text, but on the final turn the original deltas have already been
    ///   streamed — so a rewrite won't retroactively change what the caller saw.
    public func runStreaming(_ query: String) -> AsyncThrowingStream<String, Error> {
        runStreaming(query, images: [])
    }

    /// Streaming variant that accepts images for vision-capable models. The images
    /// are attached to the user turn; the rest of the ReAct loop is identical.
    public func runStreaming(_ query: String, images: [LLMImage]) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { [weak self] continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    _ = try await self.runLoop(
                        query: query,
                        images: images,
                        onText: { continuation.yield($0) }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
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