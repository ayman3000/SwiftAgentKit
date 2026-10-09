import Testing
import Foundation
import LLMProviderKit
@testable import SwiftAgentKit

/// With a ContextManager the agent sends from the whole stored history:
/// ContextSift bounds what is sent. The fit-to-80%-of-window trim used to
/// slide the window on every call once the STORED history passed it, and the
/// token trim after each step deleted history for good. What is left is an
/// overflow-only safety net, and every trim is reported.
struct HistoryTrimTests {
    private struct OutputTool: AgentTool {
        let name = "make_output"
        let description = "Make some output."
        let parameters = ToolParameters(properties: [
            "n": ToolParameterProperty(type: "integer", description: "which"),
        ], required: ["n"])
        let size: Int
        func execute(parameters: [String: Any]) async throws -> AgentToolResult {
            .success(toolCallId: "", toolName: name, result: String(repeating: "x", count: size))
        }
    }

    final class Trims: @unchecked Sendable {
        private let lock = NSLock()
        private var removed: [Int] = []
        func add(_ n: Int) { lock.withLock { removed.append(n) } }
        var all: [Int] { lock.withLock { removed } }
    }

    /// Four tool steps, then "done".
    static func fourSteps() -> [[LLMToolCall]] {
        (1...4).map { [LLMToolCall(id: "m\($0)", name: "make_output", arguments: #"{"n":\#($0)}"#)] } + [[]]
    }

    private static func agent(_ provider: ScriptedProvider, size: Int, contextManager: ContextManager?,
                              contextWindow: Int = 4_096, maxMessages: Int = 50) -> (Agent, Trims) {
        let agent = Agent(config: AgentConfig(provider: provider, model: "mock", systemPrompt: "BASE", maxTurns: 6,
                                              contextWindow: contextWindow, maxMessages: maxMessages,
                                              tools: [OutputTool(size: size)], contextManager: contextManager,
                                              loopDetection: nil))
        let trims = Trims()
        agent.onEvent { event in
            if case .historyTrimmed(let removed, _) = event { trims.add(removed) }
        }
        return (agent, trims)
    }

    @Test func withAContextManagerTheStoredHistoryIsNotTrimmedFirst() async throws {
        let provider = ScriptedProvider(turns: Self.fourSteps())
        // Window 6,144: the old trim line (80% of window − reserve) is 3,276
        // tokens. Four 4,000-character outputs put the stored history well
        // past it; the sifted request (three short receipts, one output, the
        // tool definitions) stays well under it, so the safety net never acts.
        let (agent, trims) = Self.agent(provider, size: 4_000,
                                        contextManager: ContextManager(summaryLength: 40, inlineBudgetChars: 2_000),
                                        contextWindow: 6_144)
        _ = try await agent.run("do the task")
        // The stored history is past the old trim line…
        let stored = agent.conversation.estimateTotalTokens(agent.conversation.allMessages())
        #expect(stored > agent.conversation.fitBudgetTokens)
        // …yet the last request carries every step: three as receipts, the active one inline.
        let last = try #require(provider.captured.last)
        #expect(last.messages.filter { $0.role == .assistant }.count == 4)
        #expect(last.messages.filter { $0.role == .assistant && $0.content.contains(ContextManager.receiptHeader) }.count == 3)
        #expect(trims.all.isEmpty)
        // Nothing stored was deleted: system, task, four calls and results, the answer.
        #expect(agent.conversation.allMessages().count == 11)
    }

    @Test func aSiftedRequestTooBigForTheWindowFallsBackAndSaysSo() async throws {
        let provider = ScriptedProvider(turns: Self.fourSteps())
        // A budget that never sifts: the request outgrows the window instead.
        let (agent, trims) = Self.agent(provider, size: 3_000, contextManager: ContextManager(inlineBudgetChars: 100_000))
        _ = try await agent.run("do the task")
        #expect(!trims.all.isEmpty)
        let last = try #require(provider.captured.last)
        #expect(last.messages.filter { $0.role == .assistant }.count < 4)
        #expect(last.messages.contains { $0.role == .user && $0.content == "do the task" })
        // A note added for one call only (the progress nudge, turns 3 and 5
        // of 6) survives the fallback: it is not stored, so not trimmed.
        #expect(provider.captured[4].messages.contains { $0.role == .system && $0.content.contains("[Progress check]") })
        // The fallback is per call: the stored history is complete.
        #expect(agent.conversation.allMessages().count == 11)
    }

    /// A tool with a long description, so the tool block is a large share of
    /// a small window: the messages alone always fit, the request does not.
    private struct WideTool: AgentTool {
        let name = "make_output"
        let description = "Make some output. " + String(repeating: "Detail. ", count: 300)   // 2,418 characters
        let parameters = ToolParameters(properties: [
            "n": ToolParameterProperty(type: "integer", description: "which"),
        ], required: ["n"])
        func execute(parameters: [String: Any]) async throws -> AgentToolResult {
            .success(toolCallId: "", toolName: name, result: String(repeating: "x", count: 600))
        }
    }

    /// The safety net counts what the call sends besides the messages. The
    /// messages here stay far under the bound; with the tool definitions the
    /// third and fourth calls pass it, and fall back with room left for them.
    @Test func theSafetyNetCountsTheToolDefinitions() async throws {
        let provider = ScriptedProvider(turns: (1...3).map {
            [LLMToolCall(id: "w\($0)", name: "make_output", arguments: #"{"n":\#($0)}"#)]
        } + [[]])
        let agent = Agent(config: AgentConfig(provider: provider, model: "mock", systemPrompt: "BASE", maxTurns: 6,
                                              contextWindow: 4_096, tools: [WideTool()],
                                              contextManager: ContextManager(inlineBudgetChars: 100_000),
                                              loopDetection: nil, progressNudgeFractions: []))
        let trims = Trims()
        agent.onEvent { event in
            if case .historyTrimmed(let removed, _) = event { trims.add(removed) }
        }
        _ = try await agent.run("do the task")
        let last = try #require(provider.captured.last)
        let messageTokens = agent.conversation.estimateTotalTokens(agent.conversation.allMessages())
        #expect(messageTokens < agent.conversation.fitBudgetTokens)   // the messages alone fit
        #expect(!trims.all.isEmpty)
        #expect(last.messages.filter { $0.role == .assistant }.count < 3)
        #expect(last.messages.contains { $0.role == .user && $0.content == "do the task" })
        // Nothing stored was deleted: system, task, three calls and results, the answer.
        #expect(agent.conversation.allMessages().count == 9)
    }

    @Test func aCapTrimIsReported() async throws {
        let provider = ScriptedProvider(turns: [
            [LLMToolCall(id: "m1", name: "make_output", arguments: #"{"n":1}"#)],
            [LLMToolCall(id: "m2", name: "make_output", arguments: #"{"n":2}"#)],
            [],
        ])
        let (agent, trims) = Self.agent(provider, size: 10, contextManager: nil, maxMessages: 4)
        _ = try await agent.run("do the task")
        #expect(trims.all.contains { $0 > 0 })
    }

    @Test func aConversationCanSkipTheTokenTrim() {
        let conversation = Conversation(contextWindow: 3_000, maxMessages: 0)
        conversation.setSystemMessage(.system("sys"))
        conversation.append(.user("task"))
        for i in 0..<6 { conversation.append(.assistant(String(repeating: "\(i)", count: 2_000))) }
        #expect(conversation.trim(byTokens: false).removed == 0)
        #expect(conversation.allMessages().count == 8)
        #expect(conversation.trim().removed > 0)
    }
}
