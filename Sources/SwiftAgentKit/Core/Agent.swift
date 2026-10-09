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

    /// How much work the model should spend on each response. `nil` sends
    /// nothing, which is what every run did before this existed. Effort shapes
    /// every output token, not only thinking, so a lower level also makes the
    /// agent's tool calls fewer and terser.
    ///
    /// Only set this for a model whose catalog entry carries
    /// `LLMModelCapability.reasoningEffort`: at least one provider answers an
    /// unsupported level with HTTP 400. Hold one level for the life of a
    /// conversation — providers render it into the prompt, so changing it
    /// mid-run invalidates prompt caching.
    public var reasoningEffort: LLMReasoningEffort?

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

    /// Fractions of `maxTurns` at which a one-line progress note is injected
    /// into the model's context ("you have used N of M turns — re-check the
    /// objective, stop grinding a single subproblem"). Catches slow-burn
    /// thrash that loop detection (same call, same args) can't see. Empty
    /// disables. Default [0.5, 0.8].
    public var progressNudgeFractions: [Double]

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

    /// Turn ceiling for a child agent. Bounded side-tasks finish well inside
    /// the default; a child that must READ a lot (reviewing a codebase, say)
    /// needs more, so the app can raise it. Applied as min(maxTurns, this).
    public var maxSubAgentTurns: Int

    /// Provider/model that CHILD agents run on. nil = inherit the parent's.
    /// Lets an app route delegated side-tasks to a cheaper or faster model
    /// while the parent keeps the strong one (plan/verify on the strong
    /// model, execute the bulk of tool calls on the cheap one).
    public var subAgentProvider: (any LLMProvider)?
    public var subAgentModel: String?
    /// Reasoning effort for CHILD agents. nil = the parent's. Delegated
    /// pieces rarely need the parent's depth; a lower level saves tokens.
    public var subAgentReasoningEffort: LLMReasoningEffort?
    /// Whether the sub-agent model accepts images. When false the child is not
    /// given vision tools and is told so — a text-only child handed
    /// `view_image` fails the whole delegation the first time it tries.
    public var subAgentCanSeeImages: Bool

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

    /// Stalled-stream policy for streamed model calls: a call with no progress
    /// for the policy's limit is retried once, then reported. nil = off.
    public var stallPolicy: StreamStallPolicy?
    /// Longest a single streamed call may only reason — no answer text, no
    /// tool call — before it is stopped and the model is told to act. nil = no
    /// limit. Long single thinks (11–23 min, some after the work was done)
    /// looked like a frozen app (xontel review, 2026-09-28).
    public var maxReasoningSeconds: TimeInterval?

    /// Tool groups whose definitions are sent only after the model loads them
    /// with `load_tools` (MCP servers, say). Empty = every tool always sent.
    public var toolGroups: [DeferredToolGroup]

    /// Writes the summary when the history is compacted (mid-run near the
    /// limit, or after a context-length error). nil = never compact.
    public var contextCompactor: (any ContextCompactor)?
    /// Compact before the next call once the last prompt passes this share of
    /// the window. nil = only on a context-length error.
    public var compactAtFraction: Double?

    public init(
        provider: any LLMProvider,
        model: String? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        topP: Double? = nil,
        reasoningEffort: LLMReasoningEffort? = nil,
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
        maxSubAgentTurns: Int = SubAgentSpawner.maxChildTurns,
        subAgentProvider: (any LLMProvider)? = nil,
        subAgentModel: String? = nil,
        subAgentReasoningEffort: LLMReasoningEffort? = nil,
        subAgentCanSeeImages: Bool = true,
        maxVerificationRetries: Int = 3,
        loopDetection: LoopDetectionConfig? = .default,
        parallelToolCalls: Bool = false,
        progressNudgeFractions: [Double] = [0.5, 0.8],
        stallPolicy: StreamStallPolicy? = nil,
        toolGroups: [DeferredToolGroup] = [],
        maxReasoningSeconds: TimeInterval? = nil,
        contextCompactor: (any ContextCompactor)? = nil,
        compactAtFraction: Double? = nil
    ) {
        self.contextCompactor = contextCompactor
        self.compactAtFraction = compactAtFraction
        self.provider = provider
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.topP = topP
        self.reasoningEffort = reasoningEffort
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
        self.maxSubAgentTurns = maxSubAgentTurns
        self.subAgentProvider = subAgentProvider
        self.subAgentModel = subAgentModel
        self.subAgentReasoningEffort = subAgentReasoningEffort
        self.subAgentCanSeeImages = subAgentCanSeeImages
        self.maxVerificationRetries = maxVerificationRetries
        self.loopDetection = loopDetection
        self.parallelToolCalls = parallelToolCalls
        self.stallPolicy = stallPolicy
        self.toolGroups = toolGroups
        self.maxReasoningSeconds = maxReasoningSeconds
        self.progressNudgeFractions = progressNudgeFractions
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

    public nonisolated let config: AgentConfig

    /// Who this agent is to the file tools (`FileStateRegistry`).
    nonisolated let fileIdentity = UUID()

    /// Tool registry (thread-safe).
    public nonisolated let tools: ToolRegistry

    /// Tool dispatcher (thread-safe).
    public nonisolated let dispatcher: ToolDispatcher

    /// Conversation memory.
    public nonisolated let conversation: Conversation

    /// Agent state — cross-turn mutable key-value store.
    public nonisolated let state: AgentState

    /// Optional persistent memory store. When set, the agent injects the memory
    /// context block into the system prompt and auto-registers `RememberTool`,
    /// which only notes into `memoryInbox`. `UpdateAgentProfileTool` is never
    /// auto-registered: the app registers it where it wants it.
    public private(set) var memoryStore: (any AgentMemoryStore)?
    /// The project whose memory joins the global set for this agent's runs.
    public private(set) var memoryProject: String?
    /// Notes `remember` made during runs, waiting for the app to file them.
    public private(set) var memoryInbox: MemoryInbox?

    /// Text appended to the system prompt on every run, right after memory —
    /// the app's per-run context (Naseem: lessons for this project and these
    /// tools). Given the names of the tools registered on this agent.
    private var runContextProvider: (@Sendable ([String]) async -> String)?

    /// Optional persistent goal store. When set, `run(_:trackGoal:)` persists goal
    /// progress and results.
    public private(set) var goalStore: (any AgentGoalStore)?

    /// Skill registry for progressive disclosure (optional).
    public nonisolated let skillRegistry: SkillRegistry

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
    public private(set) var skillStore: (any AgentSkillStore)?

    /// Lifecycle callbacks (intercept-able).
    public private(set) var callbacks: AgentCallbacks?

    /// Planner (optional).
    public private(set) var planner: (any AgentPlanner)?

    /// Repair-retry policy.
    public private(set) var repairRetryPolicy: RepairRetryPolicy

    /// Plan continuation policy.
    public private(set) var planContinuationPolicy: PlanContinuationPolicy

    /// Observers.
    ///
    /// Kept `nonisolated` behind a lock (rather than actor-isolated) so events
    /// are delivered synchronously, in call order, exactly as the pre-actor
    /// class did — an unstructured hop per event would lose FIFO ordering and
    /// could deliver events after `run()` returns.
    private nonisolated(unsafe) var observers: [any AgentObserver] = []
    private nonisolated let observersLock = NSLock()

    /// Fire-and-forget registration tasks created by the synchronous public API.
    /// `run(_:)` awaits these before reading registries so tool/skill registration
    /// cannot race with the first model request.
    ///
    /// `nonisolated(unsafe)`: `init` must append the `delegate_task` registration
    /// after `self` has escaped (see `subAgentSpawner`), where isolated property
    /// access is forbidden. Safe: during `init` nothing else touches the agent,
    /// and every post-init access is actor-isolated.
    private nonisolated(unsafe) var pendingRegistrationTasks: [Task<Void, Never>] = []

    /// The latest queued registration (never cleared): the next one waits
    /// for it, so registrations land in call order even while
    /// `awaitPendingRegistrations` is draining the list. Same safety as
    /// `pendingRegistrationTasks`.
    private nonisolated(unsafe) var registrationTail: Task<Void, Never>?

    /// Logger.
    public private(set) var logger: AgentLogger

    /// Estimated token count of the most recent prompt actually sent to the model
    /// (after context management / trimming) — i.e. what the model really saw, not
    /// the full stored history. Useful for a context-usage indicator.
    public private(set) var lastPromptTokens = 0

    /// `PromptDigest.hex` of the system text sent on the latest run's first
    /// model call; nil before any. Lets an app tell whether a reply started
    /// from the same system prompt as the reply before — a changed one is a
    /// prompt-cache miss for the whole conversation.
    public private(set) var firstRequestSystemDigest: String?

    /// Set at the start of a run; the next request built records its digest.
    private var firstRequestPending = false
    /// The overflow safety net's cut: the id of the last stored message calls
    /// leave out (with every older evictable step). Sticky until the request
    /// passes the bound again; cleared by compaction, or when that message is
    /// no longer stored.
    private var overflowCutAfter: UUID?
    /// The id of the current run's task message: the overflow net never
    /// leaves it out, whatever user-role nudges the run appends after it.
    private var runTaskID: UUID?

    /// Actor-isolated run/cancel state — actor serialization is the guard now.
    private var isRunActive = false

    /// Guards `_isCancelled`. Mirrors the `observersLock` pattern used for
    /// observers: the flag must be readable synchronously from arbitrary threads
    /// (spawner cancellation must be visible immediately, without an async hop),
    /// so it lives behind a plain NSLock rather than actor isolation.
    private nonisolated let cancellationLock = NSLock()
    private nonisolated(unsafe) var _isCancelled = false

    /// Whether the current run has been cancelled.
    ///
    /// Synchronously observable from any thread — `SubAgentSpawner.cancelAll()`
    /// calls `markCancelled()` while holding its own lock, and this read must
    /// return `true` immediately afterwards without an async hop.
    /// Guarded by `cancellationLock`; do not access `_isCancelled` directly.
    public nonisolated var isCancelled: Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return _isCancelled
    }

    /// Set the cancellation flag synchronously.  Called by `cancel()` (actor
    /// method) and by `SubAgentSpawner` (synchronous, off-actor).
    nonisolated func markCancelled() {
        cancellationLock.lock()
        _isCancelled = true
        cancellationLock.unlock()
    }

    /// Reset the cancellation flag at the start of a new run.
    private nonisolated func resetCancellationFlag() {
        cancellationLock.lock()
        _isCancelled = false
        cancellationLock.unlock()
    }

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

    /// Set the LLM-retry base delay. Intended for test use only; allows tests to
    /// speed up backoff without resorting to direct property mutation across the
    /// actor boundary.
    func setLlmRetryBaseDelay(_ delay: TimeInterval) { llmRetryBaseDelay = delay }

    // MARK: - Init

    deinit { FileStateRegistry.shared.forget(agent: fileIdentity) }

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
                trackRegistration { [tools] in await tools.register(tool) }
            }
        }

        // Register the context manager's artifact-retrieval tools so the model
        // can pull full tool outputs back from external storage on demand.
        if let contextManager = config.contextManager {
            for tool in contextManager.artifactTools {
                trackRegistration { [tools] in await tools.register(tool) }
            }
        }

        // Apply autonomous mode (skips the confirmation gate) if configured.
        if config.autonomousMode {
            trackRegistration { [dispatcher] in await dispatcher.setAutonomousMode(true) }
        }

        // Deferred tool groups: `load_tools` exists only when something is deferred.
        if config.toolGroups.contains(where: { !$0.alwaysLoaded }) {
            let loadTool = LoadToolsTool(handle: AgentHandle(self))
            trackRegistration { [tools] in await tools.register(loadTool) }
        }

        // Sub-agents: register the delegation tool. The spawner strips this
        // tool (and sets enableSubAgents=false) on children, so delegation is
        // one level deep.
        if config.enableSubAgents {
            let spawner = SubAgentSpawner(parent: self, concurrencyLimit: config.maxSubAgentConcurrency)
            self.subAgentSpawner = spawner
            let delegateTool = DelegateTaskTool(spawner: spawner, emit: { [weak self] event in
                self?.emitEvent(event)
            })
            trackRegistration { [tools] in await tools.register(delegateTool) }
        }
    }

    // MARK: - Deferred tool groups

    /// Loaded group ids, in load order (their tools go last, in this order).
    private(set) var loadedToolGroupIDs: [String] = []

    /// Groups that are hidden until loaded.
    private var deferredGroups: [DeferredToolGroup] { config.toolGroups.filter { !$0.alwaysLoaded } }

    /// Load groups for the rest of the conversation; the reply says what happened.
    public func loadToolGroups(_ ids: [String]) -> String {
        var loaded: [String] = [], already: [String] = [], unknown: [String] = []
        for id in ids {
            guard let group = deferredGroups.first(where: { $0.id == id }) else { unknown.append(id); continue }
            if loadedToolGroupIDs.contains(group.id) { already.append(id) }
            else { loadedToolGroupIDs.append(group.id); loaded.append(id) }
        }
        var lines: [String] = []
        for id in loaded {
            let names = deferredGroups.first { $0.id == id }?.toolNames ?? []
            lines.append("Loaded \(id): \(names.joined(separator: ", ")). Available from your next step.")
        }
        if !already.isEmpty { lines.append("Already loaded: \(already.joined(separator: ", ")).") }
        if !unknown.isEmpty {
            let available = deferredGroups.map(\.id).sorted().joined(separator: ", ")
            lines.append("No tool group named \(unknown.joined(separator: ", ")). Groups you can load: \(available).")
        }
        return lines.joined(separator: "\n")
    }

    /// The deferred groups a list of tool names or group ids points at (a
    /// skill's `tools`). Names this agent doesn't have match nothing.
    func toolGroupIDs(matching entries: [String]) -> [String] {
        let wanted = Set(entries)
        return deferredGroups.filter { wanted.contains($0.id) || !wanted.isDisjoint(with: $0.toolNames) }.map(\.id)
    }

    /// Carry a parent's loaded groups into a child agent.
    func setLoadedToolGroups(_ ids: [String]) { loadedToolGroupIDs = ids }

    /// Tools sent to the model now: everything not deferred, then each loaded
    /// group's tools in load order — so loading never moves what came before.
    private func visibleTools(_ all: [any AgentTool]) -> [any AgentTool] {
        let hidden = Set(deferredGroups.flatMap(\.toolNames))
        var visible = all.filter { !hidden.contains($0.name) }
        let byName = Dictionary(all.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for id in loadedToolGroupIDs {
            guard let group = deferredGroups.first(where: { $0.id == id }) else { continue }
            visible += group.toolNames.compactMap { byName[$0] }
        }
        return visible
    }

    /// The prompt's index of loadable groups: sorted and unaffected by loading,
    /// so the prompt prefix stays byte-stable.
    private func toolGroupIndex() -> String {
        let groups = deferredGroups.sorted { $0.id < $1.id }
        guard !groups.isEmpty else { return "" }
        let lines = groups.map { "- \($0.id): \($0.description) (\($0.toolNames.count) tools)" }
        return "\n\nTool groups you can load (call load_tools with their ids before using them):\n"
            + lines.joined(separator: "\n")
    }

    /// The deferred group a tool belongs to, when it isn't loaded yet.
    private func unloadedGroup(ofTool name: String) -> DeferredToolGroup? {
        deferredGroups.first { $0.toolNames.contains(name) && !loadedToolGroupIDs.contains($0.id) }
    }

    // MARK: - Reconfiguration (idle-only)

    private func requireIdle() throws {
        guard !isRunActive else {
            throw AgentError.runInProgress
        }
    }

    /// Attach a memory store, optionally naming the project this agent is
    /// working in (only that project's memory joins the global set in the
    /// system prompt) and the inbox `remember` notes into. Pass the same
    /// inbox to every agent of one conversation so notes survive a rebuild;
    /// without one the agent makes its own.
    public func setMemoryStore(_ store: (any AgentMemoryStore)?, project: String? = nil,
                               inbox: MemoryInbox? = nil) throws {
        try requireIdle()
        memoryStore = store
        memoryProject = project
        guard store != nil else {
            // No stale memory tool may keep writing into an unreachable inbox
            // or a detached store.
            memoryInbox = nil
            trackRegistration { [tools] in
                await tools.unregister(named: "remember")
                await tools.unregister(named: "update_agent_profile")
            }
            return
        }
        let notes = inbox ?? MemoryInbox()
        memoryInbox = notes
        register(RememberTool(inbox: notes, activeProject: project))
    }
    public func setGoalStore(_ store: (any AgentGoalStore)?) throws { try requireIdle(); goalStore = store }

    /// Set (or clear) the per-run context provider. Idle-only, like the other setters.
    public func setRunContextProvider(_ provider: (@Sendable ([String]) async -> String)?) throws {
        try requireIdle()
        runContextProvider = provider
    }
    public func setSkillStore(_ store: (any AgentSkillStore)?) throws {
        try requireIdle()
        skillStore = store
        guard let store = store else { return }
        register(LearnSkillTool(store: store, registry: skillRegistry))
        register(UseSkillTool(registry: skillRegistry, handle: AgentHandle(self)))
        trackRegistration { [skillRegistry] in
            if let skills = try? await store.loadAll() {
                await skillRegistry.registerAll(skills)
            }
        }
    }
    public func setCallbacks(_ newCallbacks: AgentCallbacks?) throws { try requireIdle(); callbacks = newCallbacks }
    public func setPlanner(_ newPlanner: (any AgentPlanner)?) throws { try requireIdle(); planner = newPlanner }
    public func setRepairRetryPolicy(_ policy: RepairRetryPolicy) throws { try requireIdle(); repairRetryPolicy = policy }
    public func setPlanContinuationPolicy(_ policy: PlanContinuationPolicy) throws { try requireIdle(); planContinuationPolicy = policy }
    public func setLogger(_ newLogger: AgentLogger) throws { try requireIdle(); logger = newLogger }

    // MARK: - Tools

    /// Enable/disable autonomous mode at runtime. When `true`, tools marked
    /// `requiresConfirmation` run without prompting `onToolConfirmation`.
    public func setAutonomousMode(_ enabled: Bool) {
        trackRegistration { [dispatcher] in await dispatcher.setAutonomousMode(enabled) }
    }

    /// Register a tool. Registrations run in call order, so a later
    /// registration of the same name always wins: an app replacing a
    /// framework tool (Naseem's `learn_skill`, registered after
    /// `setSkillStore`) gets the same tool — and the same tool block on the
    /// wire — on every engine. An app that registers its own `learn_skill`
    /// BEFORE `setSkillStore` loses to the framework's.
    public func register(_ tool: any AgentTool) {
        trackRegistration { [tools] in await tools.register(tool) }
    }

    /// Register multiple tools (in call order, like `register(_:)`).
    public func registerAll(_ toolsToRegister: [any AgentTool]) {
        trackRegistration { [tools] in await tools.registerAll(toolsToRegister) }
    }

    /// Every registered tool, by name, once the registrations still in
    /// flight have landed (`register` is fire-and-forget).
    public func registeredTools() async -> [any AgentTool] {
        await awaitPendingRegistrations()
        return await tools.allTools()
    }

    /// Set context fields for tools (e.g. current directory, selected files).
    public func setToolContext(_ context: [String: Any]) {
        // Swift 6: [String: Any] is not Sendable — wrap in @unchecked Sendable box
        let box = ToolContextBox(values: context)
        trackRegistration { [dispatcher] in await dispatcher.setContext(box.values) }
    }

    /// Register a skill for progressive disclosure.
    public func registerSkill(_ skill: AgentSkill) {
        trackRegistration { [skillRegistry] in await skillRegistry.register(skill) }
    }

    /// Register multiple skills.
    public func registerSkills(_ skills: [AgentSkill]) {
        trackRegistration { [skillRegistry] in await skillRegistry.registerAll(skills) }
    }

    /// Queue registration work behind everything queued before it (the
    /// tail), so it all lands in call order, whichever setter queued the
    /// earlier work. Independent Tasks left the winner of a same-name
    /// registration to scheduling.
    ///
    /// `nonisolated` so `init` can use it after `self` has escaped (it cannot
    /// call isolated methods there); every other caller is actor-isolated,
    /// which is what keeps the `nonisolated(unsafe)` state safe.
    private nonisolated func trackRegistration(_ work: @escaping @Sendable () async -> Void) {
        let previous = registrationTail
        let task = Task {
            await previous?.value
            await work()
        }
        registrationTail = task
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
    public nonisolated func addObserver(_ observer: any AgentObserver) {
        observersLock.lock()
        defer { observersLock.unlock() }
        observers.append(observer)
    }

    /// Remove a previously-added observer (matched by identity).
    ///
    /// Long-lived agents outlive the views that observe them; callers must
    /// remove their observer when torn down, otherwise observers accumulate and
    /// each event is delivered multiple times.
    public nonisolated func removeObserver(_ observer: any AgentObserver) {
        observersLock.lock()
        defer { observersLock.unlock() }
        observers.removeAll { $0 === observer }
    }

    /// Add a block-based observer, returning the observer token so it can later
    /// be passed to `removeObserver(_:)`.
    @discardableResult
    public nonisolated func onEvent(_ block: @Sendable @escaping (AgentEvent) -> Void) -> any AgentObserver {
        let observer = BlockObserver(block)
        addObserver(observer)
        return observer
    }

    private nonisolated func emit(_ event: AgentEvent) {
        observersLock.lock()
        let snapshot = observers
        observersLock.unlock()
        for observer in snapshot {
            observer.onEvent(event)
        }
    }

    /// Internal event entry point for sub-agent machinery (forwards to observers).
    nonisolated func emitEvent(_ event: AgentEvent) {
        emit(event)
    }

    // MARK: - Cancellation

    /// Cancel the current agent run (and any live sub-agents).
    public func cancel() {
        markCancelled()
        subAgentSpawner?.cancelAll()
    }

    /// Cancel from OUTSIDE the actor, immediately.
    ///
    /// `cancel()` is actor-isolated, so a caller has to `await` it, and an
    /// actor busy inside a long tool call may not service that hop for a
    /// while — which is exactly the moment a person is pressing Stop. The
    /// flag itself is guarded by a plain lock and needs no isolation, so set
    /// it synchronously here and let the sub-agent teardown follow on the
    /// actor. After this returns, `isCancelled` is already true and the run
    /// loop stops at its next check.
    public nonisolated func requestCancel() {
        markCancelled()
        Task { await self.cancelSubAgents() }
    }

    /// The actor-isolated half of `requestCancel()`.
    func cancelSubAgents() {
        subAgentSpawner?.cancelAll()
    }

    private func resetCancellation() {
        resetCancellationFlag()
        subAgentSpawner?.resetCancellation()
    }

    /// Whether an LLM-call error is worth retrying. Transient failures (network
    /// blips, 5xx, 429 rate-limit, Ollama load/degenerate bodies) are retried;
    /// permanent client errors (4xx other than 429, malformed request,
    /// unsupported op) are not — retrying them only burns the backoff schedule
    /// before surfacing the same error.
    /// Quota exhaustion masquerading as a 429: the limit resets in HOURS
    /// (ChatGPT Plus "usage_limit_reached" observed live with
    /// resets_in_seconds:10654), so seconds of backoff only stall every
    /// message ~30s before failing anyway. Rate-limit 429s carry no such
    /// marker and stay retryable.
    private static func isQuotaExhaustedMessage(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("usage_limit_reached") || t.contains("insufficient_quota")
    }

    static func isRetryableLLMError(_ error: Error) -> Bool {
        // A stall already got its one retry in executeTurn; the generic
        // backoff would turn it into six stalls in a row.
        if error is LLMStreamStalled { return false }
        switch error {
        case let llm as LLMError:
            switch llm {
            case .httpError(let code, let body):
                if code == 429, let body,
                   isQuotaExhaustedMessage(String(decoding: body, as: UTF8.self)) {
                    return false                      // quota exhausted — resets in hours
                }
                return code == 429 || code >= 500   // rate-limit + server errors
            case .invalidRequest, .unsupportedOperation, .unknownProvider:
                return false                          // permanent client errors
            case .networkError(let message):
                // "Nothing is listening" is not transient: a fresh install
                // without Ollama running would otherwise sit through the full
                // retry backoff (~40s of silence) before erroring. Genuine
                // blips (resets, timeouts, dropped connections) stay retryable.
                let m = message.lowercased()
                return !(m.contains("could not connect") || m.contains("connection refused"))
            case .providerError(let message):
                return !isQuotaExhaustedMessage(message)  // transient unless quota-exhausted
            case .invalidResponse, .streamingError:
                return true                           // transient (incl. Ollama load bodies)
            }
        default:
            return true                               // unknown/network errors: retry
        }
    }

    private func beginRunIfIdle() -> Bool {
        guard !isRunActive else { return false }
        isRunActive = true
        resetCancellationFlag()
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
    /// Turn numbers at which progress nudges fire. Only interior turns qualify
    /// (a nudge at turn 1 or the final turn is noise), each fraction once.
    static func nudgeTurns(maxTurns: Int, fractions: [Double]) -> Set<Int> {
        guard maxTurns > 0 else { return [] }
        return Set(fractions.compactMap { fraction -> Int? in
            guard fraction > 0, fraction < 1 else { return nil }
            let turn = Int((Double(maxTurns) * fraction).rounded())
            return turn > 1 && turn < maxTurns ? turn : nil
        })
    }

    /// The transient progress note injected at nudge turns.
    static func progressNudge(turn: Int, maxTurns: Int) -> String {
        """
        [Progress check] You have used \(turn) of \(maxTurns) turns. Re-read the \
        objective and your plan. If most recent turns went into one stubborn \
        subproblem (e.g. one failing test), STOP grinding it: summarize what you \
        tried, state the blocker, and either switch approach or finish with a \
        report and a question. Do not repeat an approach that has already failed.
        """
    }

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
    private func runLoop(query: String, images: [LLMImage], onText: (@Sendable (String) -> Void)?, onReasoning: (@Sendable (String) -> Void)? = nil, onTurnCompleted: (@Sendable (String, Bool) -> Void)? = nil) async throws -> String {
        // The file tools tell agents apart by this, so one agent can't
        // overwrite a file another changed since it last looked.
        try await FileStateRegistry.$currentAgent.withValue(fileIdentity) {
            try await runLoopBody(query: query, images: images, onText: onText,
                                  onReasoning: onReasoning, onTurnCompleted: onTurnCompleted)
        }
    }

    private func runLoopBody(query: String, images: [LLMImage], onText: (@Sendable (String) -> Void)?, onReasoning: (@Sendable (String) -> Void)?, onTurnCompleted: (@Sendable (String, Bool) -> Void)?) async throws -> String {
        guard beginRunIfIdle() else {
            throw AgentError.runInProgress
        }
        defer { endRun() }

        await awaitPendingRegistrations()
        resetCancellation()
        firstRequestPending = true
        firstRequestSystemDigest = nil   // this run's, never the previous run's
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
        let task: AgentMessage = images.isEmpty ? .user(query) : .user(query, images: images)
        runTaskID = task.id
        conversation.append(task)

        // Get registered tools and strengthen system prompt (must happen before skill injection)
        let registeredToolsEarly = await tools.allTools()
        var effectiveSystemPrompt = config.systemPrompt ?? ""

        // Persistent memory must be part of every model call. Loading it at run
        // time ensures facts saved by earlier runs are immediately available.
        if let memoryStore {
            let memoryContext = await memoryStore.loadContextBlock(project: memoryProject)
            if !memoryContext.isEmpty {
                if !effectiveSystemPrompt.isEmpty {
                    effectiveSystemPrompt += "\n\n"
                }
                effectiveSystemPrompt += memoryContext
            }
        }

        // The app's per-run context (built now, so what changed since the last
        // run — a lesson filed after it — is used from this one).
        if let runContextProvider {
            let extra = await runContextProvider(registeredToolsEarly.map(\.name))
            if !extra.isEmpty {
                if !effectiveSystemPrompt.isEmpty { effectiveSystemPrompt += "\n\n" }
                effectiveSystemPrompt += extra
            }
        }

        if !registeredToolsEarly.isEmpty {
            let hiddenNames = Set(deferredGroups.flatMap(\.toolNames))
            let toolNames = registeredToolsEarly.map { $0.name }.filter { !hiddenNames.contains($0) }.joined(separator: ", ")
            let toolInstruction = """

            You have access to the following tools: \(toolNames).
            IMPORTANT: When the user's request requires action (reading files, running commands, searching, creating, etc.), you MUST use the available tools instead of answering from memory. Call the appropriate tool to get real information, then use the tool results to formulate your answer. Do not guess or hallucinate results — always call the tool to get the actual data.
            """
            effectiveSystemPrompt += toolInstruction
        }

        // Model-driven skills: a compact, query-independent index of every
        // skill goes into the system prompt; the model loads full
        // instructions on demand with `use_skill`. The index is byte-stable
        // (alphabetical, changes only when skills change) so the prompt
        // prefix stays cache-friendly across steps and turns.
        let skillIndex = await skillRegistry.skillIndex() + toolGroupIndex()
        if !skillIndex.isEmpty || !effectiveSystemPrompt.isEmpty {
            conversation.setSystemMessage(.system(effectiveSystemPrompt + skillIndex))
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

        // Tool definitions are rebuilt per call (below): a group loaded
        // mid-run must appear on the very next call.

        // 3. Agent loop
        if config.maxTurns > 0 && !registeredTools.isEmpty {
            // ReAct loop with tools
            var pendingNudges = Self.nudgeTurns(maxTurns: config.maxTurns,
                                                fractions: config.progressNudgeFractions)
            while totalTurns < config.maxTurns {
                if isCancelled {
                    emit(.cancelled)
                    throw AgentError.cancelled
                }
                totalTurns += 1

                // Near the limit mid-run: summarize the older part before the
                // next call (the app saves a proper checkpoint after the run).
                if let fraction = config.compactAtFraction, config.contextCompactor != nil,
                   lastPromptTokens > Int(Double(conversation.contextWindow) * fraction) {
                    await compactHistory(reason: .nearLimit)
                }

                // The history this call starts from (see historyForCall)
                var messagesForLLM = historyForCall()
                // Budget checkpoint: transient system note for THIS call only
                // (not appended to the conversation), nudging the model to
                // reassess instead of grinding one subproblem to the turn cap.
                if pendingNudges.remove(totalTurns) != nil {
                    messagesForLLM.append(.system(
                        Self.progressNudge(turn: totalTurns, maxTurns: config.maxTurns)))
                }
                let removedCount = conversation.allMessages().count - messagesForLLM.count
                if removedCount > 0 {
                    emit(.historyTrimmed(removedCount: removedCount, remainingCount: messagesForLLM.count,
                                         reason: .fitToWindow))
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
                // Eager persistence: restart-surviving stores capture every
                // persist-worthy output, not just what sifting happens to spill.
                if let cm = config.contextManager { await cm.recordCompletedResults(results) }
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
                            trimAfterStep()
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
                let llmToolDefs = makeLLMToolDefinitions(from: visibleTools(registeredTools))
                var request = await makeLLMRequest(messagesForLLM: messagesForLLM, tools: llmToolDefs)

                // Call the provider (streamed when onText is set). Transient
                // provider errors — network blips, proxy 5xx, Ollama cloud
                // degenerate bodies — are retried with exponential backoff
                // before failing the run.
                var agentResponse: AgentLLMResponse
                var llmAttempt = 0
                var overflowCompacted = false
                while true {
                    do {
                        agentResponse = try await executeTurn(request: request, onText: onText, onReasoning: onReasoning)
                        break
                    } catch is CancellationError {
                        throw AgentError.cancelled
                    } catch {
                        // Too long for the model: compact once and ask again.
                        // Checked before the transient-retry path, which would
                        // otherwise resend the same oversized request.
                        if !overflowCompacted, !isCancelled, ContextCompaction.isContextOverflow(error),
                           await compactHistory(reason: .overflow) != nil {
                            overflowCompacted = true
                            messagesForLLM = historyForCall()
                            request = await makeLLMRequest(messagesForLLM: messagesForLLM, tools: llmToolDefs)
                            continue
                        }
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
                        throw Self.providerFailure(error)
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
                        conversation.append(.user(reasoningTimedOut
                            ? "You have been reasoning for a long time without acting, so that step was stopped. Stop deliberating: check what you need with a tool call, or give your answer now."
                            : "You produced internal reasoning but no answer and no tool calls. Continue: call tools if you need information, then give your final answer."))
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
                // Eager persistence: restart-surviving stores capture every
                // persist-worthy output, not just what sifting happens to spill.
                if let cm = config.contextManager { await cm.recordCompletedResults(results) }
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
                trimAfterStep()
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
            let messagesForLLM = historyForCall()
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
                agentResponse = try await executeTurn(request: request, onText: onText, onReasoning: onReasoning)
                // Time-boxed think with nothing said: ask once more, to answer now.
                if reasoningTimedOut, agentResponse.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    conversation.append(.assistant(""))
                    conversation.append(.user("You have been reasoning for a long time without answering, so that step was stopped. Give your answer now."))
                    let again = await makeLLMRequest(messagesForLLM: historyForCall())
                    agentResponse = try await executeTurn(request: again, onText: onText, onReasoning: onReasoning)
                }
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
                throw Self.providerFailure(error)
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
            if sig.hasPrefix("cycle[") {
                conversation.append(.user(
                    "You're repeating the tool cycle \(sig) — \(count) rounds with no "
                    + "new information. Break the cycle: the state will not change by "
                    + "looking again. Act on what you have, change approach, or finish "
                    + "and summarize."))
            } else {
                let toolName = String(sig.split(separator: ":", maxSplits: 1).first ?? Substring(sig))
                conversation.append(.user(
                    "You've called `\(toolName)` with the same arguments \(count) times "
                    + "without new progress. Change your approach, or finish and summarize "
                    + "what you have. Do not repeat that call."))
            }
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
        onText: (@Sendable (String) -> Void)?,
        onReasoning: (@Sendable (String) -> Void)? = nil
    ) async throws -> AgentLLMResponse {
        guard let onText else {
            let response = try await config.provider.complete(request)
            return AgentLLMResponse.from(response)
        }

        var request = request
        if let policy = config.stallPolicy { request.stallTimeout = policy.limit(for: request) }
        let started = Date()
        do {
            return try await streamTurn(request: request, onText: onText, onReasoning: onReasoning)
        } catch let stall as LLMStreamStalled where !textShown {
            // Nothing the user saw is lost: ask again, once.
            logger.warning("\(type(of: config.provider).name) made no progress for \(Int(stall.seconds)) s; retrying the call once.")
            return try await streamTurn(request: request, onText: onText, onReasoning: onReasoning)
        } catch {
            let seconds = Date().timeIntervalSince(started)
            if seconds > 120 { logger.info("A streamed model call ended after \(Int(seconds)) s with: \(error.localizedDescription)") }
            throw error
        }
    }

    /// Whether the current turn's answer text has reached the caller — after
    /// that a retry would repeat what the user already read.
    private var textShown = false
    /// The last streamed call was stopped for reasoning past the time box.
    private var reasoningTimedOut = false

    private func streamTurn(
        request: LLMRequest,
        onText: @escaping @Sendable (String) -> Void,
        onReasoning: (@Sendable (String) -> Void)?
    ) async throws -> AgentLLMResponse {
        textShown = false
        reasoningTimedOut = false
        let started = Date()
        defer {
            let seconds = Date().timeIntervalSince(started)
            if seconds > 120 { logger.info("A streamed model call took \(Int(seconds)) s (\(type(of: config.provider).name)).") }
        }
        var streamedText = ""
        // Separated reasoning (Ollama `thinking`, OpenAI `reasoning_content`,
        // Anthropic thinking deltas). Kept OUT of streamedText so it never
        // becomes the answer, but carried on the synthesized response so the
        // reasoning-only continuation guard works for streamed turns too.
        var streamedReasoning = ""
        var streamedToolCalls: [LLMToolCall] = []
        var sawNativeToolSignal = false
        // Providers report real token usage on the final `.finish` chunk; capture
        // it so the synthesized streaming response carries the model's actual
        // consumed tokens rather than dropping them (which forced cost/context
        // onto a local estimate).
        var streamedUsage: LLMUsage? = nil
        streamLoop: for try await chunk in config.provider.stream(request) {
            switch chunk {
            case .text(let text):
                streamedText += text
                textShown = true
                onText(text)
                emit(.streamChunk(text))
            case .reasoning(let delta):
                streamedReasoning += delta
                onReasoning?(delta)
                emit(.reasoningChunk(delta))
                // Time box: only reasoning so far, past the limit → stop this
                // call. The empty answer then takes the reasoning-only
                // continuation below, which tells the model to act.
                if let limit = config.maxReasoningSeconds, streamedText.isEmpty, streamedToolCalls.isEmpty,
                   Date().timeIntervalSince(started) > limit {
                    logger.info("A call reasoned for \(Int(Date().timeIntervalSince(started))) s without acting; stopping it and asking the model to act.")
                    reasoningTimedOut = true
                    break streamLoop
                }
            case .toolCall(let call):
                streamedToolCalls.append(call)
                sawNativeToolSignal = true
            case .finish(let reason, let usage):
                if let usage { streamedUsage = usage }
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
                reasoning: streamedReasoning.isEmpty ? nil : streamedReasoning,
                finishReason: .toolCalls,
                usage: streamedUsage,
                toolCalls: streamedToolCalls,
                request: request,
                providerName: type(of: config.provider).name
            )
            return AgentLLMResponse.from(response)
        }

        if sawNativeToolSignal {
            // Signaled tool use but didn't stream usable args — re-issue
            // non-streaming. A safety net for providers that only flag tool
            // use, NOT a normal path: it generates the whole step twice. Every
            // built-in provider streams whole calls (StreamedToolStepWireTests
            // pins that), so reaching here means a provider regressed. Say so.
            logger.warning("\(type(of: config.provider).name) signalled tool use without streaming usable tool calls; re-asking without streaming. This doubles the model call for this step — the provider should stream whole tool calls.")
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
            reasoning: streamedReasoning.isEmpty ? nil : streamedReasoning,
            finishReason: .stop,
            usage: streamedUsage,
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
            // describedForModel appends the tool's example calls — a schema cannot
            // express formats, id shapes or which optional fields go together.
            return LLMToolDefinition(name: tool.name, description: tool.describedForModel, parameters: paramsDict)
        }
    }

    /// Wrap a provider failure so the vendor's own sentence survives the trip
    /// to the app. `localizedDescription` alone flattens the envelope into the
    /// message and there is no way to separate them again.
    static func providerFailure(_ error: any Error) -> AgentError {
        if error is CancellationError { return .cancelled }
        let reported = error.llmUserMessage
        return .providerRefused(summary: reported.summary, details: reported.details)
    }

    /// Replace the older part of the stored history with a summary. The tail
    /// (a third of the trigger size, whole units, the latest user message
    /// always) is kept word-for-word.
    @discardableResult
    func compactHistory(reason: CompactionReason) async -> (before: Int, after: Int)? {
        guard let compactor = config.contextCompactor else { return nil }
        let all = conversation.allMessages()
        let before = conversation.estimateTotalTokens(all)
        let trigger = Double(conversation.contextWindow) * (config.compactAtFraction ?? 0.9)
        let (middle, tail) = ContextCompaction.split(all, tailBudget: max(1, Int(trigger / 3)),
                                                     estimate: conversation.estimateTokens)
        guard !middle.isEmpty, let checkpoint = await compactor.summarize(middle: middle, reason: reason) else { return nil }
        conversation.replaceNonSystemMessages(ContextCompaction.assemble(checkpoint: checkpoint, tail: tail))
        overflowCutAfter = nil
        let after = conversation.estimateTotalTokens(conversation.allMessages())
        emit(.contextCompacted(tokensBefore: before, tokensAfter: after, reason: reason))
        return (before, after)
    }

    /// The stored history a call starts from. With a ContextManager, all of
    /// it: ContextSift bounds what is sent, and trimming the stored history
    /// first slid the window on every call once it passed 80% of the window.
    /// Without one, trimmed to fit, as before.
    private func historyForCall() -> [AgentMessage] {
        config.contextManager == nil ? conversation.messagesForLLMCall() : conversation.allMessages()
    }

    /// After a step: the message-count cap, and — only without a
    /// ContextManager — the token trim. Every removal is reported, by reason.
    private func trimAfterStep() {
        let capped = conversation.trim(byTokens: false)
        if capped.removed > 0 {
            emit(.historyTrimmed(removedCount: capped.removed, remainingCount: capped.remaining,
                                 reason: .messageCap))
        }
        guard config.contextManager == nil else { return }
        let fitted = conversation.trim(byTokens: true)
        if fitted.removed > 0 {
            emit(.historyTrimmed(removedCount: fitted.removed, remainingCount: fitted.remaining,
                                 reason: .tokenBudget))
        }
    }

    /// The overflow safety net's bound: `ContextManager.overflowFraction` of
    /// the window less the output reserve (0 without a ContextManager).
    var overflowBoundTokens: Int {
        guard let manager = config.contextManager else { return 0 }
        return max(0, Int(Double(conversation.contextWindow - conversation.outputReserve) * manager.overflowFraction))
    }

    /// The steps the overflow net may leave out, oldest first: each a whole
    /// unit (a tool-call turn with its results, or one message). Never the
    /// system prompt, the run's task (the message with id `task`, recorded
    /// when the run starts; without one, the latest user message), or the
    /// step the model is waiting on: the last tool-call turn with everything
    /// after it, when that is only its results and user-role nudges (loop,
    /// repair, verifier, plan, reasoning, progress); else the last message.
    static func overflowUnits(_ stored: [AgentMessage], task: UUID? = nil) -> [[Int]] {
        let pinned = task.map { id in stored.firstIndex { $0.id == id } }
            ?? stored.lastIndex(where: { $0.role == .user })
        let nonSystem = stored.indices.filter { stored[$0].role != .system }
        guard let last = nonSystem.last else { return [] }
        var end = last
        if let head = stored.lastIndex(where: { $0.role == .assistant && $0.toolCalls?.isEmpty == false }),
           stored[(head + 1)...].allSatisfy({ $0.role == .tool || $0.role == .user }) {
            end = head
        }
        var units: [[Int]] = []
        var i = 0
        while i < end {
            let message = stored[i]
            guard message.role != .system, i != pinned else { i += 1; continue }
            var unit = [i]
            i += 1
            if message.role == .assistant, message.toolCalls?.isEmpty == false {
                while i < end, stored[i].role == .tool { unit.append(i); i += 1 }
            }
            units.append(unit)
        }
        return units
    }

    /// One trial sift for the overflow net's cut search: `view` sifted as if
    /// it were sent, with the manager's sticky state put back afterwards, so
    /// a request that is never sent commits nothing. Returns the sift and the
    /// state it would have left (committed only for the cut chosen).
    static func trialSift(_ view: [AgentMessage], manager: ContextManager,
                          systemTemplate: (String) -> String) async -> (messages: [LLMMessage], state: ContextManager.SiftState) {
        let saved = manager.siftState
        let messages = await manager.modelMessages(view, systemTemplate: systemTemplate)
        let after = manager.siftState
        manager.siftState = saved
        return (messages, after)
    }

    /// The overflow cut (how many of the oldest units a call leaves out).
    /// Held while the request at `current` fits `bound`; on a breach, the
    /// fewest more units that bring it to `target`, or all of them. Pure.
    static func overflowCut(current: Int, units: Int, bound: Int, target: Int,
                            cost: (Int) async -> Int) async -> Int {
        let current = min(current, units)
        if await cost(current) <= bound { return current }
        guard current < units else { return current }
        for cut in (current + 1)...units where await cost(cut) <= target {
            return cut
        }
        return units
    }

    /// The estimator's token count for a request: characters ÷ 3.5 plus 4 per message.
    static func estimatedTokens(_ messages: [LLMMessage]) -> Int {
        let chars = messages.reduce(0) { $0 + $1.content.count }
        return Int((Double(chars) / 3.5).rounded()) + messages.count * 4
    }

    /// The old fit's estimate (`Conversation.estimateTokens`: the
    /// conversation's tokenCounter, or characters ÷ charsPerToken with a fixed
    /// budget per tool-result image) of what one call sends: the sifted
    /// messages AND the tool definitions, which the old fit left to its 20%
    /// headroom.
    func estimatedRequestTokens(_ messages: [LLMMessage], tools: [LLMToolDefinition]) -> Int {
        let asStored = messages.map { message -> AgentMessage in
            let calls = (message.toolCalls ?? []).map { $0.name + $0.arguments }.joined()
            switch message.role {
            case .system:
                return .system(message.content)
            case .user:
                return .user(message.content, images: message.images)
            case .assistant:
                return .assistant(message.content + calls)
            case .tool:
                return .tool(results: [.success(toolCallId: message.toolCallId ?? "", toolName: nil,
                                                result: message.content, images: message.images)])
            }
        }
        return conversation.estimateTotalTokens(asStored) + toolDefinitionTokens(tools)
    }

    /// The tool definitions' share of a request, at the conversation's
    /// characters per token.
    func toolDefinitionTokens(_ tools: [LLMToolDefinition]) -> Int {
        let chars = tools.reduce(0) { $0 + Self.toolDefinitionChars($1) }
        return Int((Double(chars) / conversation.charsPerToken).rounded(.up))
    }

    /// A tool definition's size on the wire: name, description and the
    /// sorted-key JSON of its schema.
    static func toolDefinitionChars(_ tool: LLMToolDefinition) -> Int {
        let schema = (try? JSONSerialization.data(withJSONObject: tool.parameters, options: [.sortedKeys]))?.count ?? 0
        return tool.name.count + tool.description.count + schema
    }

    /// The overflow safety net (see `makeLLMRequest`): `sifted` is the sift
    /// of `messagesForLLM` (the whole stored history plus any per-call tail).
    private func overflowSafeMessages(_ messagesForLLM: [AgentMessage], sifted: [LLMMessage],
                                      tools: [LLMToolDefinition], manager: ContextManager) async -> [LLMMessage] {
        let stored = conversation.allMessages()
        let transient = messagesForLLM.count > stored.count ? Array(messagesForLLM.dropFirst(stored.count)) : []
        let units = Self.overflowUnits(stored, task: runTaskID)
        var current = 0
        if let after = overflowCutAfter {
            if let index = stored.firstIndex(where: { $0.id == after }) {
                current = units.prefix { $0.last! <= index }.count
            } else {
                overflowCutAfter = nil      // compacted or capped away
            }
        }
        let bound = overflowBoundTokens
        let target = Int(Double(bound) * min(1, max(0, manager.overflowTargetFraction)))
        let full = estimatedRequestTokens(sifted, tools: tools)
        guard current > 0 || full > bound else { return sifted }

        // Each candidate cut is a trial sift: it starts from, and leaves, the
        // state the full sift committed; only the cut chosen commits its own.
        var built: [Int: (messages: [LLMMessage], tokens: Int, state: ContextManager.SiftState)] =
            [0: (sifted, full, manager.siftState)]
        func build(_ cut: Int) async -> (messages: [LLMMessage], tokens: Int, state: ContextManager.SiftState) {
            if let done = built[cut] { return done }
            let dropped = Set(units.prefix(cut).flatMap { $0 })
            let kept = stored.indices.filter { !dropped.contains($0) }.map { stored[$0] } + transient
            let trial = await Self.trialSift(kept, manager: manager) { [state] content in state.template(content) }
            let result = (trial.messages, estimatedRequestTokens(trial.messages, tools: tools), trial.state)
            built[cut] = result
            return result
        }
        let cut = await Self.overflowCut(current: current, units: units.count, bound: bound, target: target) { cut in
            await build(cut).tokens
        }
        let chosen = await build(cut)
        manager.siftState = chosen.state
        if cut != current {
            overflowCutAfter = cut > 0 ? stored[units[cut - 1].last!].id : nil
            let removed = units.prefix(cut).reduce(0) { $0 + $1.count }
            emit(.historyTrimmed(removedCount: removed, remainingCount: stored.count - removed, reason: .overflow))
        }
        if chosen.tokens > bound {
            logger.warning("Overflow net: the request (~\(chosen.tokens) tokens) still passes its bound (\(bound)) with every evictable step left out")
        }
        return chosen.messages
    }

    private func makeLLMRequest(
        messagesForLLM: [AgentMessage],
        tools: [LLMToolDefinition] = []
    ) async -> LLMRequest {
        var llmMessages: [LLMMessage]
        if let contextManager = config.contextManager {
            // ContextSift-style: externalize completed tool exchanges.
            llmMessages = await contextManager.modelMessages(messagesForLLM) { [state] content in
                state.template(content)
            }
            // Safety net: the sifted request, tool definitions counted,
            // passes `overflowFraction` of the window less the output
            // reserve — compaction off or set later, or a model that would
            // truncate it silently (local Ollama drops the system prompt and
            // tools first). Calls then leave out the oldest whole steps,
            // measured by what is SENT (sifted), the fewest that bring the
            // request to the low watermark; that cut then holds, so the
            // prefix stays byte-identical until the bound is passed again.
            // Nothing stored is deleted; a set or moved cut is reported
            // (`.overflow`). Messages the caller added past the stored
            // history for this call only (a progress nudge) are kept after it.
            llmMessages = await overflowSafeMessages(messagesForLLM, sifted: llmMessages, tools: tools,
                                                     manager: contextManager)
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
        lastPromptTokens = Self.estimatedTokens(llmMessages)
        if firstRequestPending {
            firstRequestPending = false
            firstRequestSystemDigest = PromptDigest.hex(
                llmMessages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n"))
        }

        return LLMRequest(
            model: config.model ?? config.provider.configuration.defaultModel ?? "",
            messages: llmMessages,
            temperature: config.temperature,
            maxTokens: config.maxTokens,
            topP: config.topP,
            tools: tools,
            reasoningEffort: config.reasoningEffort
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

    /// Run one tool call exactly as if the model had made it: same dispatcher,
    /// so the approval gate, per-conversation permissions, observers and cost
    /// accounting all apply. Routines use this so that approving a routine is
    /// never a blank cheque for the tools inside it.
    /// - Parameter silent: omit the display events for this call. The routine's
    ///   own result already lists every step and its outcome, so emitting them
    ///   again shows one routine as six tool lines and reads like duplicated
    ///   work. The APPROVAL GATE is unaffected: it runs on `callbacks`, not on
    ///   the observer, so a routine is still never a blank cheque.
    public func runToolCall(_ call: AgentToolCall, silent: Bool = false) async -> AgentToolResult {
        let results = await dispatchToolCalls([call], turn: 0, query: "", actions: ToolActions(), silent: silent)
        return results.first ?? .error(toolCallId: call.id, toolName: call.name,
                                       message: "\(call.name) produced no result.")
    }

    private func dispatchToolCalls(
        _ toolCalls: [AgentToolCall],
        turn: Int,
        query: String,
        actions: ToolActions,
        silent: Bool = false
    ) async -> [AgentToolResult] {
        let dispatcherObserver = BlockObserver { [weak self] event in
            guard !silent else { return }
            self?.emit(event)
        }
        // The Stop flag, read by the dispatcher before an automatic retry.
        let stopRequested: @Sendable () -> Bool = { [weak self] in self?.isCancelled ?? true }
        // Safety net: a call into a group that isn't loaded yet loads the group
        // and asks for the call again — it isn't run blind, since the model
        // hadn't seen that tool's parameters.
        var early: [Int: AgentToolResult] = [:]
        for (i, call) in toolCalls.enumerated() {
            guard let group = unloadedGroup(ofTool: call.name) else { continue }
            _ = loadToolGroups([group.id])
            early[i] = .error(toolCallId: call.id, toolName: call.name, message:
                "\(call.name) belongs to the \(group.id) tools, which weren't loaded. They are loaded now — call \(call.name) again.")
        }
        if !early.isEmpty {
            let rest = toolCalls.enumerated().filter { early[$0.offset] == nil }
            let ran = await dispatcher.dispatch(
                calls: rest.map(\.element), state: state, turn: turn, query: query, callbacks: callbacks,
                parallel: config.parallelToolCalls, actions: actions, observer: dispatcherObserver,
                isCancelled: stopRequested)
            var byIndex = early
            for (k, entry) in rest.enumerated() where k < ran.count { byIndex[entry.offset] = ran[k] }
            return toolCalls.indices.compactMap { byIndex[$0] }
        }
        return await dispatcher.dispatch(
            calls: toolCalls,
            state: state,
            turn: turn,
            query: query,
            callbacks: callbacks,
            parallel: config.parallelToolCalls,
            actions: actions,
            observer: dispatcherObserver,
            isCancelled: stopRequested
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
                        onReasoning: { continuation.yield(.reasoningDelta($0)) },
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