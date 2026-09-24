import Foundation
import LLMProviderKit
@testable import SwiftAgentKit
import Testing

/// A stalled model call is retried once, then reported plainly — never left
/// spinning. Limits come from the host's policy and grow with the prompt.

/// Records every streamed request; stalls the first `stalls` calls, optionally
/// after streaming some answer text.
private actor StallScript {
    var requests: [LLMRequest] = []
    let stalls: Int
    let textBeforeStall: String?
    init(stalls: Int, textBeforeStall: String? = nil) { self.stalls = stalls; self.textBeforeStall = textBeforeStall }
    func next(_ r: LLMRequest) -> (stall: Bool, text: String?) {
        requests.append(r)
        return (requests.count <= stalls, textBeforeStall)
    }
}

private struct StallingProvider: LLMProvider {
    static let name = "stalling"
    let configuration = LLMProviderConfiguration(name: StallingProvider.name, baseURL: URL(string: "inproc://x")!)
    let script: StallScript
    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        LLMResponse(text: "unused", finishReason: .stop, request: request, providerName: Self.name)
    }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { c in
            Task {
                let step = await script.next(request)
                if step.stall {
                    if let t = step.text { c.yield(.text(t)) }
                    c.finish(throwing: LLMStreamStalled(seconds: request.stallTimeout ?? 0))
                } else {
                    c.yield(.text("answer"))
                    c.yield(.finish(reason: .stop, usage: nil))
                    c.finish()
                }
            }
        }
    }
}

struct StreamStallPolicyTests {
    private func run(_ script: StallScript, policy: StreamStallPolicy?, prompt: String = "hi") async -> (answer: String, error: (any Error)?) {
        let agent = Agent(config: AgentConfig(provider: StallingProvider(script: script), model: "m",
                                              maxTurns: 3, stallPolicy: policy))
        var answer = ""
        do {
            for try await chunk in agent.runStreaming(prompt) { answer += chunk }
            return (answer, nil)
        } catch { return (answer, error) }
    }

    @Test func aStallIsRetriedOnce() async {
        let script = StallScript(stalls: 1)
        let r = await run(script, policy: StreamStallPolicy(baseSeconds: 180))
        #expect(r.error == nil, "\(String(describing: r.error))")
        #expect(r.answer == "answer")
        #expect(await script.requests.count == 2)
    }

    @Test func aSecondStallIsReportedPlainly() async {
        let script = StallScript(stalls: 2)
        let r = await run(script, policy: StreamStallPolicy(baseSeconds: 180))
        #expect(await script.requests.count == 2, "one retry, not more")
        guard case .providerRefused(let summary, _)? = r.error as? AgentError else {
            Issue.record("expected providerRefused, got \(String(describing: r.error))"); return
        }
        #expect(summary.contains("stopped responding"), "\(summary)")
    }

    @Test func noRetryOnceAnswerTextWasShown() async {
        let script = StallScript(stalls: 2, textBeforeStall: "partial ")
        let r = await run(script, policy: StreamStallPolicy(baseSeconds: 180))
        #expect(await script.requests.count == 1, "retrying would repeat text the user already saw")
        #expect(r.error != nil)
    }

    @Test func theLimitComesFromThePolicyAndGrowsWithThePrompt() async {
        let small = StallScript(stalls: 0)
        _ = await run(small, policy: StreamStallPolicy(baseSeconds: 180))
        #expect(await small.requests.first?.stallTimeout == 180)

        let big = StallScript(stalls: 0)   // ~60K tokens of prompt
        _ = await run(big, policy: StreamStallPolicy(baseSeconds: 180), prompt: String(repeating: "word ", count: 50_000))
        #expect(await big.requests.first?.stallTimeout == 240)

        let huge = StallScript(stalls: 0)  // ~125K tokens
        _ = await run(huge, policy: StreamStallPolicy(baseSeconds: 180), prompt: String(repeating: "word ", count: 100_000))
        #expect(await huge.requests.first?.stallTimeout == 300)
    }

    @Test func noPolicyMeansNoWatchdog() async {
        let script = StallScript(stalls: 0)
        _ = await run(script, policy: nil)
        #expect(await script.requests.first?.stallTimeout == nil)
    }
}
