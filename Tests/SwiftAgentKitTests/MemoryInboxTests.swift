import Testing
import Foundation
@testable import SwiftAgentKit

/// During a run the model only notes things; nothing reaches the memory
/// files until the app files the notes after the run.
struct MemoryInboxTests {

    private func makeStore() -> (FileAgentMemoryStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-\(UUID().uuidString)", isDirectory: true)
        return (FileAgentMemoryStore(directory: dir), dir)
    }

    @Test func rememberRecordsANoteAndWritesNothing() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = store.snapshot()
        let inbox = MemoryInbox()
        let tool = RememberTool(inbox: inbox, activeProject: "XonTel")

        let result = try await tool.execute(parameters: ["text": "Uses plan.md for every task", "about": "project"])

        #expect(!result.isError)
        #expect(result.result.contains("filed after"))
        let notes = await inbox.notes
        #expect(notes.count == 1)
        #expect(notes.first?.text == "Uses plan.md for every task")
        #expect(notes.first?.about == .project)
        #expect(notes.first?.project == "XonTel")
        #expect(store.snapshot() == before, "no memory file changes during the run")
    }

    @Test func rememberNeedsText() async throws {
        let tool = RememberTool(inbox: MemoryInbox())
        let result = try await tool.execute(parameters: ["about": "me"])
        #expect(result.isError)
    }

    @Test func rememberAcceptsTheOldTitleAndContentShape() async throws {
        let inbox = MemoryInbox()
        let tool = RememberTool(inbox: inbox)
        _ = try await tool.execute(parameters: ["kind": "user", "title": "Name", "content": "Ayman"])
        #expect(await inbox.notes.first?.text == "Name: Ayman")
    }

    @Test func theInboxKeepsTheNewestTwenty() async {
        let inbox = MemoryInbox()
        for i in 0..<25 {
            await inbox.add(MemoryNote(text: "n\(i)", createdAt: Date(timeIntervalSince1970: Double(i))))
        }
        let notes = await inbox.notes
        #expect(notes.count == MemoryInbox.capacity)
        #expect(notes.first?.text == "n5")
        #expect(notes.last?.text == "n24")
    }

    @Test func drainEmptiesAndPutBackRetriesAtMostThreeTimes() async {
        let inbox = MemoryInbox()
        await inbox.add(MemoryNote(text: "keep me"))
        var notes = await inbox.drain()
        #expect(await inbox.count == 0)
        for _ in 0..<(MemoryInbox.maxAttempts - 1) {
            await inbox.putBack(notes)
            notes = await inbox.drain()
            #expect(notes.count == 1)
        }
        await inbox.putBack(notes)   // the third failure
        #expect(await inbox.count == 0, "a note that failed three times is given up")
    }

    @Test func putBackKeepsOrderWithNewNotes() async {
        let inbox = MemoryInbox()
        let old = MemoryNote(text: "old", createdAt: Date(timeIntervalSince1970: 1))
        await inbox.add(MemoryNote(text: "new", createdAt: Date(timeIntervalSince1970: 2)))
        await inbox.putBack([old])
        #expect(await inbox.notes.map(\.text) == ["old", "new"])
    }

    @Test func setMemoryStoreSharesTheGivenInboxAndRegistersRemember() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = Agent(config: AgentConfig(provider: ToolAwareMockProvider(), model: "mock", maxTurns: 1))
        let inbox = MemoryInbox()
        try await agent.setMemoryStore(store, project: "XonTel", inbox: inbox)
        #expect(await agent.memoryInbox === inbox)
        await agent.flushRegistrations()   // register(_:) is fire-and-forget
        let names = await agent.tools.allTools().map(\.name)
        #expect(names.contains("remember"))
        #expect(!names.contains("update_agent_profile"), "the app registers it, with its own logging")
    }

    @Test func withoutAnInboxTheAgentMakesItsOwn() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = Agent(config: AgentConfig(provider: ToolAwareMockProvider(), model: "mock", maxTurns: 1))
        try await agent.setMemoryStore(store)
        #expect(await agent.memoryInbox != nil)
    }

    // MARK: update_agent_profile

    @Test func anIdentityChangeIsAppliedAndReported() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.seedIfNeeded()
        let seen = Recorder()
        let tool = UpdateAgentProfileTool(store: store) { section, change in await seen.record(section, change) }

        let result = try await tool.execute(parameters: ["section": "identity", "change": "Name: Nemo"])

        #expect(!result.isError)
        #expect(result.result.contains("Name: Nemo"))
        let doc = store.snapshot().agentProfile
        #expect(MemoryDocuments.agentSection(.identity, in: doc) == "Name: Nemo")
        #expect(MemoryDocuments.agentSection(.mission, in: doc)
                == MemoryDocuments.agentSection(.mission, in: MemoryDocuments.defaultAgentProfile))
        let calls = await seen.calls
        #expect(calls.count == 1)
        #expect(calls.first?.0 == .identity)
        #expect(calls.first?.1.before == MemoryDocuments.defaultAgentProfile)
    }

    @Test func theMissionIsNotTheModelsToChange() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.seedIfNeeded()
        let tool = UpdateAgentProfileTool(store: store)
        let result = try await tool.execute(parameters: ["section": "mission", "change": "Sell things"])
        #expect(result.isError)
        #expect(store.snapshot().agentProfile == MemoryDocuments.defaultAgentProfile)
    }

    @Test(arguments: ["identity", "tone"])
    func aHeadingInTheChangeIsRefusedAndTheMissionStays(section: String) async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.seedIfNeeded()
        let tool = UpdateAgentProfileTool(store: store)
        let result = try await tool.execute(parameters: ["section": section,
                                                         "change": "Name: Nemo\n## Mission\nSell things"])
        #expect(result.isError)
        #expect(result.result.contains("#"))
        let doc = store.snapshot().agentProfile
        #expect(doc == MemoryDocuments.defaultAgentProfile)
        #expect(doc.components(separatedBy: "\n").filter { $0.hasPrefix("## Mission") }.count == 1)
    }

    @Test func aLongProfileChangeIsRefused() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.seedIfNeeded()
        let tool = UpdateAgentProfileTool(store: store)
        let result = try await tool.execute(parameters: ["section": "tone",
                                                         "change": String(repeating: "a", count: 1001)])
        #expect(result.isError)
        #expect(result.result.contains("1000"))
        #expect(store.snapshot().agentProfile == MemoryDocuments.defaultAgentProfile)
        let ok = try await tool.execute(parameters: ["section": "tone",
                                                     "change": String(repeating: "a", count: 1000)])
        #expect(!ok.isError)
    }

    @Test func aLongNoteIsRefused() async throws {
        let inbox = MemoryInbox()
        let tool = RememberTool(inbox: inbox)
        let result = try await tool.execute(parameters: ["text": String(repeating: "a", count: 1001)])
        #expect(result.isError)
        #expect(result.result.contains("1000"))
        #expect(await inbox.count == 0)
        let ok = try await tool.execute(parameters: ["text": String(repeating: "a", count: 1000)])
        #expect(!ok.isError)
    }

    @Test func clearingTheMemoryStoreUnregistersTheMemoryTools() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = Agent(config: AgentConfig(provider: ToolAwareMockProvider(), model: "mock", maxTurns: 1))
        try await agent.setMemoryStore(store)
        await agent.register(UpdateAgentProfileTool(store: store))
        await agent.flushRegistrations()
        #expect(await agent.tools.allTools().map(\.name).contains("remember"))
        try await agent.setMemoryStore(nil)
        await agent.flushRegistrations()
        let names = await agent.tools.allTools().map(\.name)
        #expect(!names.contains("remember"))
        #expect(!names.contains("update_agent_profile"))
        #expect(await agent.memoryInbox == nil)
    }

    @Test func putBackKeepsInsertionOrderForEqualTimes() async {
        let inbox = MemoryInbox()
        let t = Date(timeIntervalSince1970: 5)
        let failed = (0..<8).map { MemoryNote(text: "f\($0)", createdAt: t) }
        for i in 0..<8 { await inbox.add(MemoryNote(text: "n\(i)", createdAt: t)) }
        await inbox.putBack(failed)
        #expect(await inbox.notes.map(\.text) == failed.map(\.text) + (0..<8).map { "n\($0)" })
    }

    @Test func putBackOrdersByWhenNotesArrivedNotByTheirClock() async {
        // Retried notes were noted before anything now waiting; a skewed
        // createdAt must not reorder them.
        let inbox = MemoryInbox()
        let failed = [MemoryNote(text: "f0", createdAt: Date(timeIntervalSince1970: 10)),
                      MemoryNote(text: "f1", createdAt: Date(timeIntervalSince1970: 1))]
        await inbox.add(MemoryNote(text: "n0", createdAt: Date(timeIntervalSince1970: 5)))
        await inbox.putBack(failed)
        #expect(await inbox.notes.map(\.text) == ["f0", "f1", "n0"])
    }

    private actor Recorder {
        var calls: [(AgentProfileSection, MemoryChange)] = []
        func record(_ section: AgentProfileSection, _ change: MemoryChange) { calls.append((section, change)) }
    }
}
