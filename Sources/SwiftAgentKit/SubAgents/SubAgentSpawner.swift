//
//  SubAgentSpawner.swift
//  SwiftAgentKit
//
//  Builds child agents for `delegate_task` by cloning the parent's setup with
//  explicit deltas: tools minus excluded names, inherited confirmation/error
//  callbacks, fresh conversation/state, fresh ContextManager over the parent's
//  ArtifactStore, capped turns, and no further delegation (v1: one level deep).
//

import Foundation

/// An async counting gate that bounds how many sub-agents run at once.
///
/// The LLM backend is a single shared resource. Firing several sub-agents at a
/// single model in parallel (especially a cloud-hosted one) causes a
/// model-eviction reload storm — every request thrashes the others and they
/// all fail with load responses. Serializing sub-agent execution (limit 1)
/// makes each child hit a settled model; tool execution within a child still
/// runs freely. Raise the limit only when the backend genuinely serves
/// concurrent requests without thrashing.
public actor SubAgentGate {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) { self.limit = max(1, limit) }

    public func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        active += 1
    }

    public func release() {
        active -= 1
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}

/// Spawns and tracks sub-agents for a parent `Agent`.
///
/// Held by the parent when `AgentConfig.enableSubAgents` is on. Tracks live
/// children so `Agent.cancel()` can propagate into running sub-agent tools.
///
/// Constructed only by `Agent` when `enableSubAgents` is on; do not create directly.
public final class SubAgentSpawner: @unchecked Sendable {

    /// Tools a child never inherits: no recursive delegation, and memory/skill
    /// writes stay with the parent (children read memory via a prompt snapshot).
    public static let excludedToolNames: Set<String> = ["delegate_task", "remember", "learn_skill"]

    /// Turn cap for children — a delegated task is bounded by design.
    public static let maxChildTurns = 15

    private unowned let parent: Agent
    private let lock = NSLock()
    private var liveChildren: [UUID: Agent] = [:]
    private var _cancelled = false

    /// Serializes sub-agent execution so parallel `delegate_task` calls don't
    /// thrash a single model backend. `DelegateTaskTool` acquires/releases it
    /// around each child run.
    public let gate: SubAgentGate

    init(parent: Agent, concurrencyLimit: Int = 1) {
        self.parent = parent
        self.gate = SubAgentGate(limit: concurrencyLimit)
    }

    /// Build a child agent per the inheritance rules in the sub-agents spec.
    public func makeChild() async -> Agent {
        // Ensure any fire-and-forget tool/skill registrations from the parent
        // have completed before we snapshot its registries.
        await parent.flushRegistrations()

        var config = parent.config
        config.enableSubAgents = false   // defense in depth vs. recursion
        config.maxTurns = min(config.maxTurns, Self.maxChildTurns)
        config.tools = []                       // registered explicitly below

        var prompt = config.systemPrompt ?? ""
        prompt += """


        You are a sub-agent executing a delegated task. Your final message is \
        returned to the caller as data, not shown to a human — end with a \
        complete, self-contained answer containing the facts, paths, and \
        conclusions you found.
        """
        if let memoryStore = parent.memoryStore {
            let block = await memoryStore.loadContextBlock()
            if !block.isEmpty {
                prompt += "\n\n" + block
            }
        }
        config.systemPrompt = prompt

        if let parentCM = config.contextManager {
            config.contextManager = ContextManager(
                store: parentCM.store,
                maxActiveResultChars: parentCM.maxActiveResultChars,
                ledgerEntries: parentCM.ledgerEntries,
                summaryLength: parentCM.summaryLength,
                inlineBudgetChars: parentCM.inlineBudgetChars,
                keepLatestReadsInline: parentCM.keepLatestReadsInline,
                readToolNames: parentCM.readToolNames
            )
        }

        let child = Agent(config: config)
        // Flush the child's own fire-and-forget registrations (e.g. artifact
        // tools registered by ContextManager in Agent.init) before we snapshot
        // the parent's tool list — so the dedup filter below can see them.
        await child.flushRegistrations()

        // Direct actor calls (not Agent's fire-and-forget register) so the
        // child is fully wired when this method returns.
        let inherited = await parent.tools.allTools()
            .filter { !Self.excludedToolNames.contains($0.name) }
            // When the child has its own ContextManager it registers artifact_read /
            // artifact_search over the same shared store — skip the parent's copies.
            .filter { config.contextManager == nil || !["artifact_read", "artifact_search"].contains($0.name) }
        await child.tools.registerAll(inherited)
        // Sub-agents deliberately do NOT inherit skills. A child runs one bounded,
        // self-contained delegated task; matched skills would bloat its system
        // prompt (some skills are 6–28 KB), crowding a modest context window and
        // causing trim churn — which lost the child's working memory (turn-cap
        // loops, wrong answers) and, before the trim fix, emptied the request. The
        // parent keeps the skills; the child gets a lean, focused prompt.

        var childCallbacks = AgentCallbacks()
        if let parentCallbacks = parent.callbacks {
            childCallbacks.onToolConfirmation = parentCallbacks.onToolConfirmation
            childCallbacks.onToolError = parentCallbacks.onToolError
            childCallbacks.onModelError = parentCallbacks.onModelError
            // verifyCompletion deliberately NOT inherited: the parent verifies
            // the overall goal; a child verifier would double-loop.
        }
        // Built-in minimal verifier (distinct from the parent's goal verifier):
        // reasoning-heavy models sometimes end a turn with reasoning only —
        // empty content, no tool calls — which would otherwise terminate the
        // delegation with "". Nudge until the child produces an actual answer
        // (bounded by maxVerificationRetries).
        childCallbacks.verifyCompletion = { _, answer, _ in
            answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .unsatisfied(reason: "You returned an empty answer. Produce your final, self-contained answer now — it is returned to the caller as data.")
                : .satisfied
        }
        child.callbacks = childCallbacks
        return child
    }

    /// Track a live child so `cancelAll()` reaches it.
    func track(_ id: UUID, _ child: Agent) {
        lock.lock()
        liveChildren[id] = child
        let alreadyCancelled = _cancelled
        lock.unlock()
        // Close the cancel-vs-track race: if cancelAll() fired before this child
        // was registered, cancel it now so it does not run unguarded.
        if alreadyCancelled {
            child.cancel()
        }
    }

    /// Stop tracking a finished child.
    func untrack(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        liveChildren.removeValue(forKey: id)
    }

    /// Cancel every live child (called from `Agent.cancel()`).
    public func cancelAll() {
        lock.lock()
        _cancelled = true
        let children = Array(liveChildren.values)
        lock.unlock()
        for child in children {
            child.cancel()
        }
    }

    /// Reset the cancellation flag so this spawner can be reused across runs.
    func resetCancellation() {
        lock.lock(); defer { lock.unlock() }
        _cancelled = false
    }
}
