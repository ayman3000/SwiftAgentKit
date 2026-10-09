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
            if case .historyTrimmed(let removed, _, _) = event { trims.add(removed) }
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
            if case .historyTrimmed(let removed, _, _) = event { trims.add(removed) }
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

    // MARK: - Fix round 1: the overflow cut (sifted cost, sticky)

    /// Records, per call, whether the safety net moved its cut on that call.
    final class OverflowLog: @unchecked Sendable {
        private let lock = NSLock()
        private var turn = 0
        private var moved: Set<Int> = []
        private var reasons: [HistoryTrimReason] = []
        func started(_ t: Int) { lock.withLock { turn = t } }
        func trimmed(_ reason: HistoryTrimReason) {
            lock.withLock {
                reasons.append(reason)
                if reason == .overflow { moved.insert(turn) }
            }
        }
        var movedTurns: Set<Int> { lock.withLock { moved } }
        var allReasons: [HistoryTrimReason] { lock.withLock { reasons } }
    }

    /// Eleven 700-character steps under a 4,096 window, no sifting: the
    /// request passes the bound part-way through, the net cuts, and the cut
    /// then holds for several calls before the next breach moves it.
    private static func longRun() async throws -> (Agent, ScriptedProvider, OverflowLog) {
        let steps = 11
        let provider = ScriptedProvider(turns: (1...steps).map {
            [LLMToolCall(id: "m\($0)", name: "make_output", arguments: #"{"n":\#($0)}"#)]
        } + [[]])
        let agent = Agent(config: AgentConfig(provider: provider, model: "mock", systemPrompt: "BASE",
                                              maxTurns: steps + 2, contextWindow: 4_096,
                                              tools: [OutputTool(size: 700)],
                                              contextManager: ContextManager(inlineBudgetChars: 100_000),
                                              loopDetection: nil, progressNudgeFractions: []))
        let log = OverflowLog()
        agent.onEvent { event in
            switch event {
            case .llmCallStarted(let turn): log.started(turn)
            case .historyTrimmed(_, _, let reason): log.trimmed(reason)
            default: break
            }
        }
        _ = try await agent.run("do the task")
        return (agent, provider, log)
    }

    private static func hasPrefix(_ later: LLMRequest, _ earlier: LLMRequest) -> Bool {
        later.messages.count >= earlier.messages.count
            && Array(later.messages.prefix(earlier.messages.count)) == earlier.messages
    }

    @Test func twoConsecutiveFallbackCallsSendTheSamePrefix() async throws {
        let (agent, provider, log) = try await Self.longRun()
        let first = try #require(log.movedTurns.min())
        let captured = provider.captured
        // The call after the cut does not move it, and sends the cut call's
        // request unchanged, with only the new step after it.
        #expect(!log.movedTurns.contains(first + 1))
        #expect(Self.hasPrefix(captured[first], captured[first - 1]))
        // It is still a fallback call: the oldest step is left out.
        #expect(!captured[first].messages.contains { $0.toolCallId == "m1" })
        // The request the cut built fits the bound, and leaves headroom.
        let bound = await agent.overflowBoundTokens
        #expect(await agent.estimatedRequestTokens(captured[first - 1].messages, tools: captured[first - 1].tools) <= bound)
        // Nothing stored was deleted.
        #expect(agent.conversation.allMessages().count == 25)   // system, task, 11 calls and results, the answer
    }

    @Test func theCutMovesOnlyWhenTheBoundIsBreachedAgain() async throws {
        let (agent, provider, log) = try await Self.longRun()
        let captured = provider.captured
        let moved = log.movedTurns
        let first = try #require(moved.min())
        // It moves again later in the run, but not on every call.
        #expect(moved.count >= 2)
        #expect(moved.count < captured.count - first + 1)
        let bound = await agent.overflowBoundTokens
        for turn in first..<captured.count {
            let request = captured[turn]      // call turn + 1
            if moved.contains(turn + 1) {
                // A moved cut: the previous cut, grown by one step, breached.
                #expect(await agent.estimatedRequestTokens(request.messages, tools: request.tools) <= bound)
            } else {
                // A held cut: byte-identical prefix.
                #expect(Self.hasPrefix(request, captured[turn - 1]))
            }
        }
        // Only the net trimmed, and every trim says so.
        #expect(log.allReasons.allSatisfy { $0 == .overflow })
    }

    @Test func theCutNeverDropsTheStepTheModelIsWaitingOn() async throws {
        let (_, provider, _) = try await Self.longRun()
        let captured = provider.captured
        for (index, request) in captured.enumerated() where index >= 1 && index <= 11 {
            #expect(request.messages.last?.role == .tool)
            #expect(request.messages.last?.toolCallId == "m\(index)")
            #expect(request.messages.contains { $0.role == .user && $0.content == "do the task" })
        }
    }

    /// The pure decision: hold the cut while it fits the bound; on a breach,
    /// the fewest more steps that bring the request to the target.
    @Test func theCutDecision() async {
        let cost: @Sendable (Int) async -> Int = { 1_000 - 100 * $0 }
        // Fits at the current cut: held, even with the full history over.
        #expect(await Agent.overflowCut(current: 2, units: 8, bound: 800, target: 600, cost: cost) == 2)
        // Breached: the fewest steps that reach the target (600 at 4).
        #expect(await Agent.overflowCut(current: 0, units: 8, bound: 800, target: 600, cost: cost) == 4)
        #expect(await Agent.overflowCut(current: 1, units: 8, bound: 800, target: 600, cost: cost) == 4)
        // Nothing reaches it: every evictable step, never more.
        #expect(await Agent.overflowCut(current: 0, units: 3, bound: 800, target: 600, cost: cost) == 3)
    }

    @Test func theBoundIsConfigurable() {
        let manager = ContextManager()
        #expect(manager.overflowFraction == 0.8)
        manager.overflowFraction = 1.0
        manager.overflowTargetFraction = 0.6
        let child = manager.childManager()
        #expect(child.overflowFraction == 1.0)
        #expect(child.overflowTargetFraction == 0.6)
    }

    @Test func aHigherOverflowFractionLeavesTheRunToCompaction() async throws {
        // The same run as aSiftedRequestTooBigForTheWindowFallsBackAndSaysSo,
        // with the net's bound raised past what the run reaches.
        let manager = ContextManager(inlineBudgetChars: 100_000)
        manager.overflowFraction = 3.0
        let provider = ScriptedProvider(turns: Self.fourSteps())
        let (agent, trims) = Self.agent(provider, size: 3_000, contextManager: manager)
        _ = try await agent.run("do the task")
        #expect(trims.all.isEmpty)
        #expect(provider.captured.last?.messages.filter { $0.role == .assistant }.count == 4)
    }

    /// An active result too big for the bound on its own: the net leaves out
    /// every older step but never the call the model is waiting on, nor its
    /// result.
    @Test func anOversizedActiveStepIsKeptWhole() async throws {
        let provider = ScriptedProvider(turns: Self.fourSteps())
        let agent = Agent(config: AgentConfig(provider: provider, model: "mock", systemPrompt: "BASE", maxTurns: 6,
                                              contextWindow: 4_096, tools: [OutputTool(size: 7_000)],
                                              contextManager: ContextManager(inlineBudgetChars: 100_000),
                                              loopDetection: nil, progressNudgeFractions: []))
        _ = try await agent.run("do the task")
        for (index, request) in provider.captured.enumerated() where index >= 1 && index <= 4 {
            let last = try #require(request.messages.last)
            #expect(last.role == .tool && last.toolCallId == "m\(index)")
            #expect(request.messages.contains { $0.toolCalls?.contains { $0.id == "m\(index)" } == true })
            #expect(request.messages.contains { $0.role == .user && $0.content == "do the task" })
            // Older steps are all left out.
            #expect(request.messages.filter { $0.role == .tool }.count == 1)
        }
    }
}
