import Testing
import Foundation
import LLMProviderKit
@testable import SwiftAgentKit

/// A provider whose stream interleaves separated reasoning with the answer,
/// the way Ollama's `thinking` field / OpenAI `reasoning_content` arrive.
private struct ReasoningStreamProvider: LLMProvider {
    static let name = "reasoning-stream"
    let configuration = LLMProviderConfiguration(
        name: name, baseURL: URL(string: "inprocess://reasoning")!, defaultModel: "mock"
    )

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        LLMResponse(text: "final", reasoning: "thought", finishReason: .stop, request: request, providerName: Self.name)
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.reasoning("let me "))
            continuation.yield(.reasoning("think"))
            continuation.yield(.text("fin"))
            continuation.yield(.text("al"))
            continuation.yield(.finish(reason: .stop, usage: nil))
            continuation.finish()
        }
    }
}

@Suite struct StreamedReasoningTests {
    @Test func reasoningDeltasAreTaggedAndKeptOutOfText() async throws {
        let agent = Agent(config: AgentConfig(provider: ReasoningStreamProvider(), maxTurns: 3))
        var reasoning = ""
        var text = ""
        var completed: [String] = []
        for try await ev in agent.runStreamingTagged("go") {
            switch ev {
            case .reasoningDelta(let r): reasoning += r
            case .delta(let t): text += t
            case .turnCompleted(let t, _): completed.append(t)
            }
        }
        #expect(reasoning == "let me think")
        #expect(text == "final")
        #expect(completed == ["final"])
    }

    @Test func plainRunStreamingIgnoresReasoning() async throws {
        let agent = Agent(config: AgentConfig(provider: ReasoningStreamProvider(), maxTurns: 3))
        var text = ""
        for try await chunk in agent.runStreaming("go") { text += chunk }
        #expect(text == "final")
    }
}

/// First call: reasons without end (a chunk every 50 ms). Second call: answers.
private final class EndlessThinker: LLMProvider, @unchecked Sendable {
    static let name = "endless-thinker"
    let configuration = LLMProviderConfiguration(name: name, baseURL: URL(string: "inprocess://t")!, defaultModel: "m")
    private let lock = NSLock()
    private(set) var calls = 0
    /// Every `.user`-role message of the most recently sent request, in
    /// order. With progress nudges on, a transient progress note can land
    /// after the stored "stop reasoning" nudge as the call's last user
    /// message, so a test must find the right one among these rather than
    /// assume it is the last.
    private(set) var lastUserMessages: [String] = []
    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        LLMResponse(text: "done", finishReason: .stop, request: request, providerName: Self.name)
    }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let n: Int = lock.withLock {
            calls += 1
            lastUserMessages = request.messages.filter { $0.role == .user }.map(\.content)
            return calls
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                if n == 1 {
                    for _ in 0..<200 {   // 10 s of thinking, if nobody stops it
                        if Task.isCancelled { break }
                        continuation.yield(.reasoning("hmm "))
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                } else {
                    continuation.yield(.text("answer"))
                }
                continuation.yield(.finish(reason: .stop, usage: nil))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Single "Thinking…" pauses of 11, 17 and 23 minutes, some after the work
/// was done (xontel review, I-11): a call that only reasons past the limit is
/// stopped and the model is told to act.
///
/// Progress nudges stay ON (default fractions) here on purpose: with
/// `withTools: true` and `maxTurns: 4`, turn 2's stop-reasoning nudge is
/// stored, and turn 2 is also a nudge turn, so the SAME call carries both the
/// stored nudge and the transient progress note as its last two user
/// messages — the collision `AnthropicRoleAlternationTests` exercises at the
/// wire level. Disabling nudges here would hide that overlap instead of
/// exercising it, so the assertion below looks for the stop-reasoning
/// message among all of the call's user messages rather than assuming it is
/// the last one.
@Test(arguments: [false, true])
func aCallThatOnlyThinksPastTheLimitIsStoppedAndToldToAct(withTools: Bool) async throws {
    let p = EndlessThinker()
    let agent = Agent(config: AgentConfig(provider: p, maxTurns: 4, maxReasoningSeconds: 0.3))
    if withTools { await agent.register(EchoTool()) }
    let started = Date()
    var text = ""
    for try await chunk in agent.runStreaming("go") { text += chunk }
    #expect(Date().timeIntervalSince(started) < 5)          // not the full 10 s
    #expect(p.calls == 2)
    #expect(text == "answer")
    #expect(p.lastUserMessages.contains { $0.lowercased().contains("reasoning") },
            "expected the stop-reasoning nudge among the turn's user messages: \(p.lastUserMessages)")
}
