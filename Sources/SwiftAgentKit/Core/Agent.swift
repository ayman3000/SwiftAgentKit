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

    /// How many sub-agents may run concurrently. Default 1 (serialized): the LLM
    /// backend is a single shared resource, and firing parallel sub-agents at
    /// one model — a cloud model especially — triggers a model-eviction reload
    /// storm that fails them all. Raise only for a backend that truly serves
    /// concurrent requests. Tool execution within a child is unaffected.
    public var maxSubAgentConcurrency: Int

    /// Max times an unsatisfied `AgentCallbacks.verifyCompletion` verdict may
    /// re-nudge the model to keep working before the agent stops anyway. Bounds
    /// goal-driven looping (also bounded by `maxTurns`). Default 3.
    public var maxVerificationRetries: Int

    /// Runtime guard against no-progress loops (repeated identical tool calls).
    /// `nil` disables it (pre-change behavior). Default on.
    public var loopDetection: LoopDetectionConfig?

    /// When `true`, tool calls in a single turn run concurrently. Default `false`
    /// (sequential, in the order the model issued them): models routinely emit
    /// order-dependent batches (write then read, two patches to one file, UI
    /// steps) and concurrent execution silently breaks those. Opt in only when
    /// your registered tools are safe to interleave.
    public var parallelToolCalls: Bool

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
        maxSubAgentConcurrency: Int = 1,
        maxVerificationRetries: Int = 3,
        loopDetection: LoopDetectionConfig? = .default,
        parallelToolCalls: Bool = false
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
        self.maxSubAgentConcurrency = maxSubAgentConcurrency
        self.maxVerificationRetries = maxVerificationRetries
        self.loopDetection = loopDetection
        self.parallelToolCalls = parallelToolCalls
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
public actor Agent {

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
    ///
    /// `nonisolated(unsafe)`: written exactly once, in `init`, after
    /// `SubAgentSpawner(parent: self)` — an escaping use of `self`, after which
    /// a synchronous actor init loses isolated property access. Read-only
    /// thereafter, so the access is safe.
    public private(set) nonisolated(unsafe) var subAgentSpawner: SubAgentSpawner?

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

    /// Module-internal setter so cross-actor callers (e.g. `SubAgentSpawner`)
    /// can assign callbacks — actor-isolated properties cannot be written from
    /// outside the actor.
    func setCallbacks(_ callbacks: AgentCallbacks?) {
        self.callbacks = callbacks
    }

    /// Planner (optional).
    public var planner: (any AgentPlanner)?

    /// Repair-retry policy.
    public var repairRetryPolicy: RepairRetryPolicy

    /// Plan continuation policy.
    public var planContinuationPolicy: PlanContinuationPolicy

    /// Observers.
    private var observers: [any AgentObserver] = []

    /// Fire-and-forget registration tasks created by the synchronous public API.
    /// `run(_:)` awaits these before reading registries so tool/skill registration
    /// cannot race with the first model request.
    ///
    /// `nonisolated(unsafe)`: `init` must append the `delegate_task` registration
    /// after `self` has escaped (see `subAgentSpawner`), where isolated property
    /// access is forbidden. Safe: during `init` nothing else touches the agent,
    /// and every post-init access is actor-isolated.
    private nonisolated(unsafe) var pendingRegistrationTasks: [Task<Void, Never>] = []

    /// Logger.
    public var logger: AgentLogger

    /// Estimated token count of the most recent prompt actually sent to the model
    /// (after context management / trimming) — i.e. what the model really saw, not
    /// the full stored history. Useful for a context-usage indicator.
    public private(set) var lastPromptTokens = 0

    /// Actor-isolated run/cancel state — actor serialization is the guard now.
    private var isRunActive = false
    public private(set) var isCancelled = false

    /// Cap on consecutive-or-not reasoning-only continuations per run. These
    /// turns don't consume repair/verification budgets, so they need their own
    /// bound (also bounded by `maxTurns`).
    static let maxReasoningContinuations = 8

    /// Retries per LLM call on transient provider errors (network blips,
    /// proxy 5xx, Ollama cloud model-load storms). Needs enough headroom for a
    /// concurrent model load to finish — with N sub-agents hammering a cold
    /// cloud model, several consecutive requests get `done_reason:"load"`.
    static let maxLLMRetries = 5

    /// Backoff is capped at this many seconds. A recovering cloud model can
    /// become ready at any point; capping the delay means we re-poll it
    /// frequently in the tail instead of sleeping through a long exponential
    /// gap and missing the ready window. Worst-case per call: 1+2+4+8+8 ≈ 23s.
    static let maxLLMRetryBackoff: TimeInterval = 8.0

    /// Base backoff delay in seconds for LLM-call retries. Grows exponentially
    /// (base, 2×, 4×…) with random jitter added, so concurrent sub-agents don't
    /// retry in lockstep and re-collide on the still-loading model. Internal so
    /// tests can shrink it.
    var llmRetryBaseDelay: TimeInterval = 1.0

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

        // Auto-register tools passed via config.
        // (Direct stored-property appends: an actor's synchronous init cannot
        // call isolated methods like `register(_:)`.)
        if !config.tools.isEmpty {
            for tool in config.tools {
                pendingRegistrationTasks.append(Task { [tools] in await tools.register(tool) })
            }
        }

        // Register the context manager's artifact-retrieval tools so the model
        // can pull full tool outputs back from external storage on demand.
        if let contextManager = config.contextManager {
            for tool in contextManager.artifactTools {
                pendingRegistrationTasks.append(Task { [tools] in await tools.register(tool) })
            }
        }

        // Apply autonomous mode (skips the confirmation gate) if configured.
        if config.autonomousMode {
            pendingRegistrationTasks.append(Task { [dispatcher] in await dispatcher.setAutonomousMode(true) })
        }

        // Sub-agents: register the delegation tool. The spawner strips this
        // tool (and sets enableSubAgents=false) on children, so delegation is
        // one level deep.
        if config.enableSubAgents {
            let spawner = SubAgentSpawner(parent: self, concurrencyLimit: config.maxSubAgentConcurrency)
            self.subAgentSpawner = spawner
            let delegateTool = DelegateTaskTool(spawner: spawner, emit: { [weak self] event in
                Task { await self?.emitEvent(event) }
            })
            pendingRegistrationTasks.append(Task { [tools] in await tools.register(delegateTool) })
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
        pendingRegistrationTasks.append(task)
    }

    private func awaitPendingRegistrations() async {
        let tasks = pendingRegistrationTasks
        pendingRegistrationTasks.removeAll()

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
        observers.append(observer)
    }

    /// Remove a previously-added observer (matched by identity).
    ///
    /// Long-lived agents outlive the views that observe them; callers must
    /// remove their observer when torn down, otherwise observers accumulate and
    /// each event is delivered multiple times.
    public func removeObserver(_ observer: any AgentObserver) {
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
        for observer in observers {
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
        isCancelled = true
        subAgentSpawner?.cancelAll()
    }

    private func resetCancellation() {
        isCancelled = false
        subAgentSpawner?.resetCancellation()
    }

    /// Whether an LLM-call error is worth retrying. Transient failures (network
    /// blips, 5xx, 429 rate-limit, Ollama load/degenerate bodies) are retried;
    /// permanent client errors (4xx other than 429, malformed request,
    /// unsupported op) are not — retrying them only burns the backoff schedule
    /// before surfacing the same error.
    static func isRetryableLLMError(_ error: Error) -> Bool {
        switch error {
        case let llm as LLMError:
            switch llm {
            case .httpError(let code, _):
                return code == 429 || code >= 500   // rate-limit + server errors
            case .invalidRequest, .unsupportedOperation, .unknownProvider:
                return false                          // permanent client errors
            case .invalidResponse, .streamingError, .providerError, .networkError:
                return true                           // transient (incl. Ollama load bodies)
            }
        default:
            return true                               // unknown/network errors: retry
        }
    }

    private func beginRunIfIdle() -> Bool {
        guard !isRunActive else { return false }
        isRunActive = true
        isCancelled = false
        return true
    }

    private func endRun() { isRunActive = false }

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

    /// Run the agent and persist the query as an `AgentGoal` in `goalStore`.
    ///
    /// The goal is saved as `.inProgress` before the run, then updated to
    /// `.completed` (with the final answer as its summary) or `.failed` (with
    /// the error description). Requires `goalStore` to be set — with no store,
    /// this behaves exactly like `run(_:)`.
    ///
    public func run(_ query: String, trackGoal: Bool) async throws -> String {
        guard trackGoal, goalStore != nil else { return try await run(query) }

        var goal = AgentGoal(query: query, status: .inProgress)
        await persistGoal(goal)
        do {
            let answer = try await run(query)
            goal.status = .completed
            goal.summary = answer
            goal.updatedAt = Date()
            await persistGoal(goal)
            return answer
        } catch {
            goal.status = .failed
            goal.summary = error.localizedDescription
            goal.updatedAt = Date()
            await persistGoal(goal)
            throw error
        }
    }

    /// Shared ReAct implementation backing both `run(_:)` (non-streaming) and
    /// `runStreaming(_:)` (streaming). When `onText` is non-nil, each turn is
    /// streamed and assistant text deltas are delivered to `onText` as they
    /// arrive — including the final answer, token-by-token.
    private func runLoop(query: String, images: [LLMImage], onText: (@Sendable (String) -> Void)?, onTurnCompleted: (@Sendable (String, Bool) -> Void)? = nil) async throws -> String {
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
        var reasoningContinuations = 0
        let loopDetector = config.loopDetection.map { LoopDetector(config: $0) }

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
                            onTurnCompleted?(intercepted.text, true)
                            let turnActions = ToolActions()
                            let results = await dispatchToolCalls(toolCalls, turn: totalTurns, query: query, actions: turnActions)
                            toolsExecuted += results.count
                            toolErrors += results.filter(\.isError).count
                            lastTurnErrors = repairableErrors(from: results, actions: turnActions)
                            conversation.append(.tool(results: results))
                            if turnActions.shouldStop {
                                state.clearTemp()
                                return intercepted.text
                            }
                            try checkForLoop(
                                toolCalls,
                                detector: loopDetector,
                                query: query,
                                totalTurns: totalTurns,
                                toolsExecuted: toolsExecuted,
                                toolErrors: toolErrors,
                                plan: plan,
                                startTime: startTime
                            )
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
                        onTurnCompleted?(intercepted.text, false)
                        return intercepted.text
                    }
                }

                // Build LLM request (with state-templated system prompt)
                let request = await makeLLMRequest(messagesForLLM: messagesForLLM, tools: llmToolDefs)

                // Call the provider (streamed when onText is set). Transient
                // provider errors — network blips, proxy 5xx, Ollama cloud
                // degenerate bodies — are retried with exponential backoff
                // before failing the run.
                var agentResponse: AgentLLMResponse
                var llmAttempt = 0
                while true {
                    do {
                        agentResponse = try await executeTurn(request: request, onText: onText)
                        break
                    } catch is CancellationError {
                        throw AgentError.cancelled
                    } catch {
                        llmAttempt += 1
                        // Only retry TRANSIENT failures. A permanent client error
                        // (HTTP 4xx except 429 rate-limit, bad request, unsupported)
                        // will never succeed on retry — retrying it just stalls the
                        // run through the whole backoff schedule (~30s) before
                        // surfacing the same error. Fail fast on those.
                        if Self.isRetryableLLMError(error), llmAttempt <= Self.maxLLMRetries, !isCancelled {
                            emit(.llmCallRetrying(turn: totalTurns, attempt: llmAttempt, error: error.localizedDescription))
                            // Exponential backoff + jitter (0…base) so concurrent
                            // sub-agents desynchronize instead of re-colliding on
                            // the still-loading model each round.
                            let raw = llmRetryBaseDelay * pow(2, Double(llmAttempt - 1))
                            let backoff = min(raw, Self.maxLLMRetryBackoff)
                            let jitter = llmRetryBaseDelay * Double.random(in: 0...1)
                            try await Task.sleep(nanoseconds: UInt64((backoff + jitter) * 1_000_000_000))
                            continue
                        }
                        // Retries exhausted — onModelError callback can provide a fallback
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
                                onTurnCompleted?(fallback.text, false)
                                return fallback.text
                            }
                        }
                        throw AgentError.providerError(error.localizedDescription)
                    }
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

                    // Reasoning-only turn: the model thought but produced no
                    // answer and no tool calls (GLM/Kimi habit via Ollama).
                    // That's "mid-thought", not "done" — continue WITHOUT
                    // consuming the repair or verification budgets. Bounded by
                    // its own cap (and maxTurns) so a stuck model can't loop.
                    if agentResponse.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let reasoning = agentResponse.reasoning,
                       !reasoning.isEmpty,
                       reasoningContinuations < Self.maxReasoningContinuations {
                        conversation.append(.assistant(agentResponse.text))
                        conversation.append(.user(
                            "You produced internal reasoning but no answer and no tool calls. Continue: call tools if you need information, then give your final answer."))
                        reasoningContinuations += 1
                        emit(.reasoningOnlyContinuation(attempt: reasoningContinuations))
                        continue
                    }

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
                            onTurnCompleted?(blockedText, false)
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
                            onTurnCompleted?(modified, false)
                            return modified
                        }
                    }
                    state.clearTemp()
                    onTurnCompleted?(agentResponse.text, false)
                    return agentResponse.text
                }

                // Has tool calls — execute them
                emit(.toolCallsReceived(toolCalls))
                conversation.append(.assistant(content: agentResponse.text, toolCalls: toolCalls))

                // Narration precedes tool-execution events on the consumer side:
                // fire the turn-completed tag BEFORE dispatching so observers see
                // the assistant text before any tool-result events arrive.
                onTurnCompleted?(agentResponse.text, true)

                // Dispatch tool calls (with state + callbacks; sequential unless
                // `config.parallelToolCalls` opts in)
                let turnActions = ToolActions()
                let results = await dispatchToolCalls(toolCalls, turn: totalTurns, query: query, actions: turnActions)
                toolsExecuted += results.count
                toolErrors += results.filter(\.isError).count
                lastTurnErrors = repairableErrors(from: results, actions: turnActions)

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

                // A tool signalled `shouldStop` — end the loop after this turn.
                // The tool-calling turn's assistant text is the final answer.
                if turnActions.shouldStop {
                    state.clearTemp()
                    return agentResponse.text
                }

                // No-progress guard: same tool call repeating without progress.
                try checkForLoop(
                    toolCalls,
                    detector: loopDetector,
                    query: query,
                    totalTurns: totalTurns,
                    toolsExecuted: toolsExecuted,
                    toolErrors: toolErrors,
                    plan: plan,
                    startTime: startTime
                )

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
                            onTurnCompleted?(modified, false)
                            return modified
                        }
                    }
                    onTurnCompleted?(intercepted.text, false)
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
                        onTurnCompleted?(fallback.text, false)
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
                    onTurnCompleted?(modified, false)
                    return modified
                }
            }

            onTurnCompleted?(agentResponse.text, false)
            return agentResponse.text
        }
    }

    /// Feed a completed turn's tool calls to the loop detector; nudge (append a
    /// corrective user message) or throw AgentError.loopDetected on a stall.
    /// No-op when loop detection is disabled. Call once per turn AFTER the turn's
    /// tool results are appended to the conversation.
    private func checkForLoop(
        _ toolCalls: [AgentToolCall],
        detector: LoopDetector?,
        query: String,
        totalTurns: Int,
        toolsExecuted: Int,
        toolErrors: Int,
        plan: AgentPlan?,
        startTime: Date
    ) throws {
        guard let detector else { return }
        let signatures = toolCalls.map {
            LoopDetector.signature(name: $0.name, arguments: $0.parameters)
        }
        switch detector.record(signatures) {
        case .none:
            break
        case .nudge(let sig, let count):
            emit(.loopDetected(signature: sig, count: count, action: .nudged))
            let toolName = String(sig.split(separator: ":", maxSplits: 1).first ?? Substring(sig))
            conversation.append(.user(
                "You've called `\(toolName)` with the same arguments \(count) times "
                + "without new progress. Change your approach, or finish and summarize "
                + "what you have. Do not repeat that call."))
        case .stop(let sig, let count):
            emit(.loopDetected(signature: sig, count: count, action: .stopped))
            let summary = makeRunSummary(
                query: query,
                totalTurns: totalTurns,
                toolsExecuted: toolsExecuted,
                toolErrors: toolErrors,
                plan: plan,
                finalResponse: "Stopped: repeated the same action without progress.",
                startTime: startTime
            )
            emit(.finished(summary: summary))
            throw AgentError.loopDetected(signature: sig, count: count)
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
        lastPromptTokens = estimate

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
        query: String,
        actions: ToolActions
    ) async -> [AgentToolResult] {
        let dispatcherObserver = BlockObserver { [weak self] event in
            Task { await self?.emit(event) }
        }
        return await dispatcher.dispatch(
            calls: toolCalls,
            state: state,
            turn: turn,
            query: query,
            callbacks: callbacks,
            parallel: config.parallelToolCalls,
            actions: actions,
            observer: dispatcherObserver
        )
    }

    /// Track errors from the last turn (for repair-retry).
    private var lastTurnErrors: [AgentToolResult] = []

    /// Which of a turn's results should feed the repair-retry policy.
    ///
    /// - A tool that set `ToolActions.shouldRetry` makes the whole turn
    ///   retryable, even when no result is an error.
    /// - Otherwise only results the `repairRetryPolicy.isRepairable` closure
    ///   accepts count — so a custom policy can rule errors out entirely.
    private func repairableErrors(
        from results: [AgentToolResult],
        actions: ToolActions
    ) -> [AgentToolResult] {
        if actions.shouldRetry { return results }
        return results.filter { repairRetryPolicy.isRepairable($0) }
    }

    // MARK: - Streaming

    /// Run the agent in streaming mode.
    ///
    /// Alias for `runStreaming(_:)`. Earlier releases gave `stream(_:)` its own
    /// reduced execution path that skipped the run guard, planning, repair, and
    /// — critically — tool execution (streamed tool calls were dropped). It now
    /// runs the exact same lifecycle as `run(_:)`/`runStreaming(_:)`.
    @available(*, deprecated, renamed: "runStreaming(_:)")
    nonisolated public func stream(_ query: String) -> AsyncThrowingStream<String, Error> {
        runStreaming(query)
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
    nonisolated public func runStreaming(_ query: String) -> AsyncThrowingStream<String, Error> {
        runStreaming(query, images: [])
    }

    /// Streaming variant that accepts images for vision-capable models. The images
    /// are attached to the user turn; the rest of the ReAct loop is identical.
    nonisolated public func runStreaming(_ query: String, images: [LLMImage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
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

    /// Streaming variant tagging content finality. `.delta` = live text of the
    /// in-progress turn; `.turnCompleted` = one per finished turn (step vs final
    /// answer). Additive — `runStreaming` (String) is unchanged.
    nonisolated public func runStreamingTagged(_ query: String, images: [LLMImage] = []) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await self.runLoop(
                        query: query, images: images,
                        onText: { continuation.yield(.delta($0)) },
                        onTurnCompleted: { continuation.yield(.turnCompleted(text: $0, wasToolCallTurn: $1)) })
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
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