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

/// Spawns and tracks sub-agents for a parent `Agent`.
///
/// Held by the parent when `AgentConfig.enableSubAgents` is on. Tracks live
/// children so `Agent.cancel()` can propagate into running sub-agent tools.
public final class SubAgentSpawner: @unchecked Sendable {

    /// Tools a child never inherits: no recursive delegation, and memory/skill
    /// writes stay with the parent (children read memory via a prompt snapshot).
    public static let excludedToolNames: Set<String> = ["delegate_task", "remember", "learn_skill"]

    /// Turn cap for children — a delegated task is bounded by design.
    public static let maxChildTurns = 15

    private unowned let parent: Agent
    private let lock = NSLock()
    private var liveChildren: [UUID: Agent] = [:]

    public init(parent: Agent) {
        self.parent = parent
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

        // Direct actor calls (not Agent's fire-and-forget register) so the
        // child is fully wired when this method returns.
        let inherited = await parent.tools.allTools()
            .filter { !Self.excludedToolNames.contains($0.name) }
        await child.tools.registerAll(inherited)
        await child.skillRegistry.registerAll(parent.skillRegistry.allSkills())

        var childCallbacks = AgentCallbacks()
        if let parentCallbacks = parent.callbacks {
            childCallbacks.onToolConfirmation = parentCallbacks.onToolConfirmation
            childCallbacks.onToolError = parentCallbacks.onToolError
            childCallbacks.onModelError = parentCallbacks.onModelError
            // verifyCompletion deliberately NOT inherited: the parent verifies
            // the overall goal; a child verifier would double-loop.
        }
        child.callbacks = childCallbacks
        return child
    }

    /// Track a live child so `cancelAll()` reaches it.
    public func track(_ id: UUID, _ child: Agent) {
        lock.lock(); defer { lock.unlock() }
        liveChildren[id] = child
    }

    /// Stop tracking a finished child.
    public func untrack(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        liveChildren.removeValue(forKey: id)
    }

    /// Cancel every live child (called from `Agent.cancel()`).
    public func cancelAll() {
        lock.lock()
        let children = Array(liveChildren.values)
        lock.unlock()
        for child in children {
            child.cancel()
        }
    }
}
