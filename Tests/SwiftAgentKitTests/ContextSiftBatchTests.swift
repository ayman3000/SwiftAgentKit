import Testing
import Foundation
import LLMProviderKit
@testable import SwiftAgentKit

/// ContextSift that keeps the prompt prefix: evictions only in real batches,
/// the system prompt off the sifted size (and off the budget), receipts in
/// place, images kept, a child manager with every setting.
struct ContextSiftBatchTests {
    /// One completed (or, when last, active) tool step of `size` characters.
    static func step(_ i: Int, size: Int) -> [AgentMessage] {
        [.assistant(content: "", toolCalls: [AgentToolCall(id: "st\(i)", name: "run_shell")]),
         .tool(results: [.success(toolCallId: "st\(i)", toolName: "run_shell",
                                  result: String(repeating: "o", count: size))])]
    }

    /// How many calls did not extend the previous call's messages unchanged —
    /// each one is a prompt-cache break.
    static func breaks(_ outputs: [[LLMMessage]]) -> Int {
        zip(outputs, outputs.dropFirst()).filter { earlier, later in
            later.count < earlier.count || zip(earlier, later).contains { $0 != $1 }
        }.count
    }

    static func count(_ candidates: [Int], remaining: Int, budget: Int) -> Int {
        ContextManager.evictionCount(candidates: candidates, remaining: remaining, budget: budget,
                                     targetFraction: 0.5, minBatchFraction: 0.25, slackFraction: 0.1)
    }

    @Test func nothingIsEvictedUnderTheBudget() {
        #expect(Self.count([500, 500], remaining: 900, budget: 1_000) == 0)
    }

    @Test func lessThanAMinimumBatchWaits() {
        // Over budget, but only 200 of evictable output: wait for a real batch.
        #expect(Self.count([100, 100], remaining: 1_500, budget: 1_000) == 0)
    }

    @Test func aBatchFreesDownToTheTarget() {
        // floor 100, target max(500, 100 + 100) = 500: free at least 800 → three steps.
        #expect(Self.count([300, 300, 300, 300], remaining: 1_300, budget: 1_000) == 3)
    }

    @Test func aFullFloorStillEvictsAWholeBatch() {
        // floor 1,200 is over the budget: target 1,300, so at least the minimum
        // batch (250) goes in one pass — three steps — never one per call.
        #expect(Self.count([100, 100, 100], remaining: 1_500, budget: 1_000) == 3)
    }

    @Test func aZeroBudgetEvictsEverything() {
        #expect(Self.count([10, 20], remaining: 40, budget: 0) == 2)
    }

    @Test func theSystemPromptComesOffTheBudget() {
        let manager = ContextManager(inlineBudgetChars: 10_000)
        #expect(manager.messageBudget(systemChars: 0) == 10_000)
        #expect(manager.messageBudget(systemChars: 4_000) == 6_000)
        // Never below a quarter of the budget, however long the system prompt is.
        #expect(manager.messageBudget(systemChars: 9_000) == 2_500)
        #expect(manager.messageBudget(systemChars: 50_000) == 2_500)
    }

    /// The system prompt is not part of the sifted size: a system prompt that
    /// alone nearly fills the budget leaves the messages a quarter of it,
    /// instead of making every completed step evictable.
    @Test func aLongSystemPromptLeavesTheMessagesAQuarterOfTheBudget() async {
        let manager = ContextManager(inlineBudgetChars: 4_000)
        let messages: [AgentMessage] = [.system(String(repeating: "s", count: 3_900)), .user("go")]
            + Self.step(0, size: 300) + Self.step(1, size: 300) + [.assistant("done"), .user("next")]
        let out = await manager.modelMessages(messages) { $0 }
        #expect(out.filter { $0.role == .tool }.count == 2)   // nothing evicted: 610 ≤ 1,000
    }

    /// A protected read fills the budget by itself. Before batches, every call
    /// then evicted the step that had just finished, and the prefix changed on
    /// every call; now it changes once per minimum batch of new output.
    @Test func aFloorAtTheBudgetDoesNotChangeThePrefixOnEveryCall() async {
        let manager = ContextManager(maxActiveResultChars: 10_000, inlineBudgetChars: 4_000)
        var messages: [AgentMessage] = [
            .user("task"),
            .assistant(content: "", toolCalls: [AgentToolCall(id: "r1", name: "read_file",
                                                               parameters: ["path": AnyCodable("/big")])]),
            .tool(results: [.success(toolCallId: "r1", toolName: "read_file",
                                     result: String(repeating: "r", count: 4_200))]),
        ]
        var outputs: [[LLMMessage]] = []
        for i in 0..<20 {
            messages += Self.step(i, size: 200)
            outputs.append(await manager.modelMessages(messages) { $0 })
        }
        // Minimum batch 1,000 = five 200-character steps: batches at calls 6, 11 and 16.
        #expect(Self.breaks(outputs) == 3)
    }
}

extension ContextSiftBatchTests {
    @Test func anEvictedStepBecomesOneAssistantMessageInItsPlace() async {
        let manager = ContextManager(summaryLength: 40, inlineBudgetChars: 0)
        let messages: [AgentMessage] = [
            .system("sys"),
            .user("task"),
            .assistant(content: "Checking both.", toolCalls: [
                AgentToolCall(id: "a", name: "run_shell", parameters: ["command": AnyCodable("ls")]),
                AgentToolCall(id: "b", name: "fetch_url", parameters: ["url": AnyCodable("https://x")]),
            ]),
            .tool(results: [.success(toolCallId: "a", toolName: "run_shell", result: "a.txt"),
                            .success(toolCallId: "b", toolName: "fetch_url", result: "hello")]),
            .assistant("Done."),
            .user("next"),
        ]
        let out = await manager.modelMessages(messages) { $0 }
        #expect(out.map(\.role) == [.system, .user, .assistant, .assistant, .user])
        #expect(out[0].content == "sys")   // the system prompt alone
        #expect(out[2].content == "Checking both.\n\n" + ContextManager.receiptHeader
                + "\n- a run_shell(ls) → OK: a.txt\n- b fetch_url(https://x) → OK: hello\n]")
        #expect(out[2].toolCalls == nil)
    }

    /// Calls through several batches: each break is a batch, and it starts at
    /// the first newly evicted step — the system prompt, the task and every
    /// earlier receipt are the same as before.
    @Test func aLaterBatchKeepsEverythingBeforeItsFirstEvictedStep() async {
        let manager = ContextManager(inlineBudgetChars: 2_000)
        var messages: [AgentMessage] = [.system("sys"), .user("long task")]
        var outputs: [[LLMMessage]] = []
        for i in 0..<20 {
            messages += Self.step(i, size: 300)
            outputs.append(await manager.modelMessages(messages) { $0 })
        }
        var breaks = 0
        for (earlier, later) in zip(outputs, outputs.dropFirst()) {
            guard let first = zip(earlier, later).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset
            else { continue }
            breaks += 1
            #expect(first >= 2, "the system prompt and the task never change")
            #expect(later[first].role == .assistant)
            #expect(later[first].content.hasPrefix(ContextManager.receiptHeader))
            #expect(earlier[first].toolCalls?.isEmpty == false)   // it was that step's call
        }
        // Budget 1,997 (2,000 − "sys"), minimum batch 500: four steps per batch,
        // at calls 7, 11, 15 and 19.
        #expect(breaks == 4)
    }

    @Test func siftedToolResultsKeepTheirImages() async {
        let manager = ContextManager(inlineBudgetChars: 0)
        let shot = LLMImage(data: Data([1, 2, 3]), mimeType: "image/png")
        let messages: [AgentMessage] = [
            .user("look"),
            .assistant(content: "", toolCalls: [AgentToolCall(id: "s1", name: "mac_screenshot")]),
            .tool(results: [.success(toolCallId: "s1", toolName: "mac_screenshot", result: "captured", images: [shot])]),
        ]
        let out = await manager.modelMessages(messages) { $0 }
        #expect(out.first { $0.role == .tool }?.images.map(\.base64) == [shot.base64])
    }

    /// Crossing into sifting alone changes nothing: a large completed result
    /// the normal path sent whole is still sent whole until a batch, and is
    /// bounded (or evicted) only as part of one.
    @Test func enteringSiftingDoesNotTruncateACompletedResult() async {
        let manager = ContextManager(maxActiveResultChars: 1_000, inlineBudgetChars: 6_000)
        manager.minEvictionBatchFraction = 1.0   // a batch needs 6,000 evictable; there is 5,000
        var messages: [AgentMessage] = [.user("task")] + Self.step(0, size: 5_000) + [.assistant("ok")]
        let before = await manager.modelMessages(messages) { $0 }   // 5,006 ≤ 6,000: the normal path
        messages += Self.step(1, size: 1_200)                        // 6,206: sifting, but no batch
        let sifted = await manager.modelMessages(messages) { $0 }
        #expect(Array(sifted.prefix(before.count)) == before)       // step 0 still whole
        #expect(!sifted.contains { $0.content.hasPrefix(ContextManager.receiptHeader) })

        // With a batch, the large completed step goes, as a receipt.
        let batching = ContextManager(maxActiveResultChars: 1_000, inlineBudgetChars: 6_000)
        let batched = await batching.modelMessages(messages) { $0 }
        #expect(batched.contains { $0.role == .assistant && $0.content.hasPrefix(ContextManager.receiptHeader) })
    }
}
