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
