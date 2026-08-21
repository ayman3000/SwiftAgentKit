import Foundation
import LLMProviderKit
import SwiftAgentKit

/// Drives an `Agent` whose LLM backend is a `ReplayProvider`, capturing the
/// events and built requests a test needs to assert on.
///
/// **Single-use**: call `run(_:)` once per instance — events accumulate and the
/// underlying scripted responses are consumed once. Create a fresh `ReplayRun` for each test.
public final class ReplayRun: @unchecked Sendable {
    private let provider: ReplayProvider
    private let agent: Agent

    private let lock = NSLock()
    private var _events: [AgentEvent] = []

    public init(
        scenario: Scenario,
        tools: [any AgentTool] = [],
        systemPrompt: String? = nil,
        maxTurns: Int = 20,
        contextManager: ContextManager? = nil,
        loopDetection: LoopDetectionConfig? = .default
    ) {
        let provider = ReplayProvider(scenario: scenario)
        self.provider = provider
        let config = AgentConfig(
            provider: provider,
            systemPrompt: systemPrompt,
            maxTurns: maxTurns,
            tools: tools,
            contextManager: contextManager,
            loopDetection: loopDetection
        )
        self.agent = Agent(config: config)
    }

    /// Run the agent to completion and return the final answer.
    @discardableResult
    public func run(_ query: String) async throws -> String {
        let observer = agent.onEvent { [weak self] event in
            guard let self else { return }
            self.lock.lock(); self._events.append(event); self.lock.unlock()
        }
        do {
            let answer = try await agent.run(query)
            agent.removeObserver(observer)
            return answer
        } catch {
            agent.removeObserver(observer)
            throw error
        }
    }

    /// Run via the STREAMING path (`onText` non-nil) to completion, returning
    /// the concatenated streamed text. Use this to exercise streaming-only
    /// behavior (e.g. provider usage captured from the final `.finish` chunk).
    @discardableResult
    public func runStreaming(_ query: String) async throws -> String {
        let observer = agent.onEvent { [weak self] event in
            guard let self else { return }
            self.lock.lock(); self._events.append(event); self.lock.unlock()
        }
        defer { agent.removeObserver(observer) }
        var full = ""
        for try await chunk in agent.runStreaming(query) { full += chunk }
        return full
    }

    public var capturedRequests: [LLMRequest] { provider.capturedRequests }

    public var events: [AgentEvent] {
        lock.lock(); defer { lock.unlock() }
        return _events
    }

    /// Ordered names of tools the loop actually executed.
    public var toolCallNames: [String] {
        events.compactMap { event in
            if case .toolExecutionStarted(let call) = event { return call.name }
            return nil
        }
    }
}
