import Foundation
import LLMProviderKit
@testable import SwiftAgentKit
import Testing

// Compaction: the older middle of a long conversation is replaced by one
// summary, the recent tail stays word-for-word (Naseem, 2026-10-03).

struct ContextCompactionTests {
    private func est(_ m: AgentMessage) -> Int { m.content.count + (m.toolResults?.reduce(0) { $0 + $1.result.count } ?? 0) }

    @Test func tailKeepsWholeToolExchangesAndAtLeastOneUnit() {
        let call = AgentToolCall(id: "c1", name: "run_shell", parameters: [:])
        let msgs: [AgentMessage] = [
            .user(String(repeating: "a", count: 100)),
            .assistant(String(repeating: "b", count: 100)),
            .user("second"),
            .assistant(content: "", toolCalls: [call]),
            .tool(results: [.success(toolCallId: "c1", toolName: "run_shell", result: String(repeating: "x", count: 50))]),
            .assistant("done"),
        ]
        let (middle, tail) = ContextCompaction.split(msgs, tailBudget: 70, estimate: est)
        #expect(tail.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(middle.count == 2)
        #expect(tail.first?.role != .tool)
    }

    @Test func latestUserIsPulledIntoTheTailWhenItsTurnIsHuge() {
        var msgs: [AgentMessage] = [.user("old"), .assistant("old reply"), .user("THE TASK")]
        for i in 0..<5 {
            let call = AgentToolCall(id: "c\(i)", name: "t", parameters: [:])
            msgs.append(.assistant(content: "", toolCalls: [call]))
            msgs.append(.tool(results: [.success(toolCallId: "c\(i)", toolName: "t", result: String(repeating: "r", count: 100))]))
        }
        let (middle, tail) = ContextCompaction.split(msgs, tailBudget: 150, estimate: est)
        #expect(tail.first?.content == "THE TASK")
        #expect(tail.dropFirst().first?.role == .assistant)
        #expect(!middle.contains { $0.content == "THE TASK" })
        #expect(middle.contains { $0.content == "old" })
    }

    @Test func assembleMergesIntoFirstUserOrPrepends() {
        let merged = ContextCompaction.assemble(checkpoint: "SUM", tail: [.user("hi"), .assistant("yo")])
        #expect(merged.count == 2)
        #expect(merged[0].content == "SUM" + ContextCompaction.endOfSummary + "hi")
        let prepended = ContextCompaction.assemble(checkpoint: "SUM", tail: [.assistant("yo")])
        #expect(prepended.map(\.role) == [.user, .assistant])
        let empty = ContextCompaction.assemble(checkpoint: "SUM", tail: [])
        #expect(empty.map(\.role) == [.user, .assistant])
    }

    @Test func overflowErrorsAreRecognised() {
        #expect(ContextCompaction.isContextOverflow(LLMError.httpError(413, nil)))
        #expect(ContextCompaction.isContextOverflow(LLMError.httpError(400, Data(#"{"error":{"code":"context_length_exceeded"}}"#.utf8))))
        #expect(ContextCompaction.isContextOverflow(AgentError.providerRefused(summary: "prompt is too long: 210000 tokens > 200000 maximum", details: nil)))
        #expect(!ContextCompaction.isContextOverflow(LLMError.httpError(401, Data("invalid api key".utf8))))
        #expect(!ContextCompaction.isContextOverflow(LLMError.httpError(429, nil)))
    }

    @Test func replaceKeepsTheSystemMessage() {
        let conv = Conversation(contextWindow: 8192, maxMessages: 0)
        conv.setSystemMessage(.system("sys"))
        conv.append(.user("a")); conv.append(.assistant("b"))
        conv.replaceNonSystemMessages([.user("c")])
        #expect(conv.allMessages().map(\.content) == ["sys", "c"])
    }
}

private final class OverflowProvider: LLMProvider, @unchecked Sendable {
    static let name = "overflow"
    let configuration = LLMProviderConfiguration(name: OverflowProvider.name, baseURL: URL(string: "inproc://x")!)
    private let lock = NSLock()
    private var failures: Int
    private(set) var calls = 0
    init(failures: Int) { self.failures = failures }
    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let fail: Bool = lock.withLock { calls += 1; if failures > 0 { failures -= 1; return true }; return false }
        if fail { throw LLMError.httpError(400, Data(#"{"error":{"code":"context_length_exceeded"}}"#.utf8)) }
        return LLMResponse(text: "done", finishReason: .stop, request: request, providerName: Self.name)
    }
}

private final class StubCompactor: ContextCompactor, @unchecked Sendable {
    private let lock = NSLock()
    private var _reasons: [CompactionReason] = []
    var reasons: [CompactionReason] { lock.withLock { _reasons } }
    func summarize(middle: [AgentMessage], reason: CompactionReason) async -> String? {
        lock.withLock { _reasons.append(reason) }
        return "SUMMARY of \(middle.count)"
    }
}

struct AgentCompactionTests {
    private func agent(_ p: any LLMProvider, _ c: StubCompactor?) async -> Agent {
        let a = Agent(config: AgentConfig(provider: p, model: "m", maxTurns: 4, contextWindow: 4000, maxMessages: 0,
                                          tools: [EchoTool()], contextCompactor: c))
        for i in 0..<6 {
            a.conversation.append(.user("question \(i) " + String(repeating: "q", count: 1500)))
            a.conversation.append(.assistant("answer \(i) " + String(repeating: "a", count: 1500)))
        }
        return a
    }

    @Test func overflowCompactsOnceAndRetries() async throws {
        let p = OverflowProvider(failures: 1), c = StubCompactor()
        let a = await agent(p, c)
        let out = try await a.run("go on")
        #expect(out == "done")
        #expect(c.reasons == [.overflow])
        #expect(p.calls == 2)
        let first = a.conversation.allMessages().first { $0.role != .system }
        #expect(first?.content.hasPrefix("SUMMARY of") == true)
    }

    @Test func aSecondOverflowSurfacesTheError() async {
        let p = OverflowProvider(failures: 5), c = StubCompactor()
        let a = await agent(p, c)
        await #expect(throws: (any Error).self) { try await a.run("go on") }
        #expect(c.reasons == [.overflow])
    }

    @Test func withoutACompactorOverflowFailsAsBefore() async {
        let p = OverflowProvider(failures: 1)
        let a = await agent(p, nil)
        await #expect(throws: (any Error).self) { try await a.run("go on") }
        #expect(p.calls == 1)
    }
}

private final class CallThenAnswer: LLMProvider, @unchecked Sendable {
    static let name = "call-then-answer"
    let configuration = LLMProviderConfiguration(name: CallThenAnswer.name, baseURL: URL(string: "inproc://x")!)
    private let lock = NSLock()
    private var n = 0
    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let first: Bool = lock.withLock { n += 1; return n == 1 }
        if first {
            return LLMResponse(text: "", finishReason: .toolCalls,
                               toolCalls: [LLMToolCall(id: "e1", name: "echo", arguments: #"{"message":"hi"}"#)],
                               request: request, providerName: Self.name)
        }
        return LLMResponse(text: "done", finishReason: .stop, request: request, providerName: Self.name)
    }
}

extension AgentCompactionTests {
    @Test func nearTheLimitMidRunCompactsBeforeTheNextCall() async throws {
        let c = StubCompactor()
        let a = Agent(config: AgentConfig(provider: CallThenAnswer(), model: "m", maxTurns: 4, contextWindow: 4000,
                                          maxMessages: 0, tools: [EchoTool()], contextCompactor: c, compactAtFraction: 0.2))
        for i in 0..<6 {
            a.conversation.append(.user("question \(i) " + String(repeating: "q", count: 1500)))
            a.conversation.append(.assistant("answer \(i) " + String(repeating: "a", count: 1500)))
        }
        _ = try await a.run("go on")
        #expect(c.reasons.first == .nearLimit)
    }

    @Test func noFractionMeansNoMidRunCompaction() async throws {
        let c = StubCompactor()
        let a = Agent(config: AgentConfig(provider: CallThenAnswer(), model: "m", maxTurns: 4, contextWindow: 4000,
                                          maxMessages: 0, tools: [EchoTool()], contextCompactor: c))
        for i in 0..<6 { a.conversation.append(.user("q\(i) " + String(repeating: "q", count: 1500))); a.conversation.append(.assistant("a")) }
        _ = try await a.run("go on")
        #expect(c.reasons.isEmpty)
    }
}
