import Testing
import Foundation
import LLMProviderKit
@testable import SwiftAgentKit

/// A memory store whose block is whatever the test says it is now.
final class TextMemoryStore: AgentMemoryStore, @unchecked Sendable {
    private let lock = NSLock()
    private var current: String
    init(_ text: String) { current = text }
    var text: String {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
    func save(_ entry: AgentMemoryEntry) async throws {}
    func delete(id: String) async throws {}
    func loadAll() async throws -> [AgentMemoryEntry] { [] }
    func load(kind: AgentMemoryKind) async throws -> [AgentMemoryEntry] { [] }
    func loadContextBlock() async -> String { text }
}

/// Counts how often the per-run block is built.
final class RunContextCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}

/// A memory store that invalidates the agent's frozen run context from
/// inside `loadContextBlock`, simulating an edit landing while a build is
/// suspended on this very await (actors are reentrant).
final class InvalidatingMemoryStore: AgentMemoryStore, @unchecked Sendable {
    private let text: String
    /// Set after the agent exists; `loadContextBlock` calls back into it.
    var agent: Agent?
    init(_ text: String) { self.text = text }
    func save(_ entry: AgentMemoryEntry) async throws {}
    func delete(id: String) async throws {}
    func loadAll() async throws -> [AgentMemoryEntry] { [] }
    func load(kind: AgentMemoryKind) async throws -> [AgentMemoryEntry] { [] }
    func loadContextBlock() async -> String {
        if let agent { await agent.invalidateRunContext() }
        return text
    }
}

private struct FixedCompactor: ContextCompactor {
    func summarize(middle: [AgentMessage], reason: CompactionReason) async -> String? { "SUMMARY" }
}

/// With `freezeRunContext`, a chat's system prompt is the same bytes from run
/// to run: memory, the app's per-run block and the skill index are built once
/// and kept until invalidated, compacted, or replaced by a restored copy.
struct FrozenRunContextTests {
    /// An agent whose system prompt has every dynamic part.
    static func agent(freeze: Bool, provider: ScriptedProvider, memory: TextMemoryStore,
                      systemPrompt: String = "BASE") async throws -> Agent {
        let counter = RunContextCounter()
        let agent = Agent(config: AgentConfig(provider: provider, model: "mock", systemPrompt: systemPrompt,
                                              maxTurns: 1, contextCompactor: FixedCompactor(),
                                              compactAtFraction: 0.9, freezeRunContext: freeze))
        try await agent.setMemoryStore(memory)
        try await agent.setRunContextProvider { _ in "RUN \(counter.next())" }
        await agent.registerSkill(AgentSkill(name: "alpha", description: "First skill.", instructions: "Do alpha."))
        return agent
    }

    static func systems(_ provider: ScriptedProvider) -> [String] {
        provider.captured.map { $0.messages.first { $0.role == .system }?.content ?? "" }
    }

    @Test func byDefaultEveryRunReadsMemoryAgain() async throws {
        let provider = ScriptedProvider(turns: [])
        let memory = TextMemoryStore("MEMORY v1")
        let agent = try await Self.agent(freeze: false, provider: provider, memory: memory)
        _ = try await agent.run("one")
        memory.text = "MEMORY v2"
        _ = try await agent.run("two")
        let systems = Self.systems(provider)
        #expect(systems[0].contains("MEMORY v1") && systems[0].contains("RUN 1"))
        #expect(systems[1].contains("MEMORY v2") && systems[1].contains("RUN 2"))
        #expect(await agent.frozenRunContext == nil)
    }

    @Test func aFrozenRunContextKeepsTheFirstRunsParts() async throws {
        let provider = ScriptedProvider(turns: [])
        let memory = TextMemoryStore("MEMORY v1")
        let agent = try await Self.agent(freeze: true, provider: provider, memory: memory)
        _ = try await agent.run("one")
        memory.text = "MEMORY v2"   // the keeper filed something after the first reply
        await agent.registerSkill(AgentSkill(name: "beta", description: "Second skill.", instructions: "Do beta."))
        _ = try await agent.run("two")
        let systems = Self.systems(provider)
        #expect(systems[0] == systems[1])
        #expect(systems[1].contains("MEMORY v1") && systems[1].contains("RUN 1"))
        #expect(!systems[1].contains("beta"))
        let frozen = try #require(await agent.frozenRunContext)
        #expect(frozen.memory == "MEMORY v1")
        #expect(frozen.runContext == "RUN 1")
        #expect(frozen.skillIndex.contains("alpha"))
    }

    @Test func invalidatingRebuildsOnTheNextRun() async throws {
        let provider = ScriptedProvider(turns: [])
        let memory = TextMemoryStore("MEMORY v1")
        let agent = try await Self.agent(freeze: true, provider: provider, memory: memory)
        _ = try await agent.run("one")
        memory.text = "MEMORY v2"
        await agent.invalidateRunContext()
        _ = try await agent.run("two")
        let systems = Self.systems(provider)
        #expect(systems[1].contains("MEMORY v2") && systems[1].contains("RUN 2"))
    }

    @Test func aCompactionClearsIt() async throws {
        let provider = ScriptedProvider(turns: [])
        let agent = try await Self.agent(freeze: true, provider: provider, memory: TextMemoryStore("MEMORY v1"))
        _ = try await agent.run("one")
        #expect(await agent.frozenRunContext != nil)
        agent.conversation.append([.user(String(repeating: "a", count: 20_000)),
                                   .assistant(String(repeating: "b", count: 20_000)),
                                   .user("now"), .assistant("ok")])
        #expect(await agent.compactHistory(reason: .nearLimit) != nil)
        #expect(await agent.frozenRunContext == nil)
    }

    /// The relaunch case: the frozen context goes through JSON (as an app
    /// saves it) into a new agent, which sends the same system prompt even
    /// though memory changed in between.
    @Test func aRestoredContextIsUsedOnTheNextRun() async throws {
        let first = ScriptedProvider(turns: [])
        let memory = TextMemoryStore("MEMORY v1")
        let a = try await Self.agent(freeze: true, provider: first, memory: memory)
        _ = try await a.run("one")
        let saved = try JSONEncoder().encode(try #require(await a.frozenRunContext))
        memory.text = "MEMORY v2"
        let second = ScriptedProvider(turns: [])
        let b = try await Self.agent(freeze: true, provider: second, memory: memory)
        try await b.restoreRunContext(try JSONDecoder().decode(FrozenRunContext.self, from: saved))
        _ = try await b.run("two")
        #expect(Self.systems(second)[0] == Self.systems(first)[0])
    }

    /// A changed engine (another configured prompt, other tools) never sends
    /// a stale mix: the restored context is ignored and built fresh.
    @Test func aChangedBaseIgnoresARestoredContext() async throws {
        let first = ScriptedProvider(turns: [])
        let memory = TextMemoryStore("MEMORY v1")
        let a = try await Self.agent(freeze: true, provider: first, memory: memory)
        _ = try await a.run("one")
        let saved = try #require(await a.frozenRunContext)
        memory.text = "MEMORY v2"
        let second = ScriptedProvider(turns: [])
        let b = try await Self.agent(freeze: true, provider: second, memory: memory, systemPrompt: "OTHER BASE")
        try await b.restoreRunContext(saved)
        _ = try await b.run("two")
        #expect(Self.systems(second)[0].contains("MEMORY v2"))
        #expect(await b.frozenRunContext?.memory == "MEMORY v2")
    }

    /// An invalidate landing while the build is suspended on the memory
    /// read (actors are reentrant across that await) must not be clobbered
    /// by the stale parts the build started with. Run 1 still gets the
    /// stale parts it was already mid-build on (the running reply keeps its
    /// prompt), but nothing is frozen, so run 2 rebuilds and sees the edit.
    @Test func anInvalidateDuringTheBuildIsNotOverwritten() async throws {
        let provider = ScriptedProvider(turns: [])
        let memory = InvalidatingMemoryStore("MEMORY v1")
        let counter = RunContextCounter()
        let agent = Agent(config: AgentConfig(provider: provider, model: "mock", systemPrompt: "BASE",
                                              maxTurns: 1, freezeRunContext: true))
        try await agent.setMemoryStore(memory)
        try await agent.setRunContextProvider { _ in "RUN \(counter.next())" }
        memory.agent = agent
        _ = try await agent.run("one")
        // Run 1 saw the memory it started reading, even though the agent
        // was invalidated mid-build.
        #expect(Self.systems(provider)[0].contains("MEMORY v1"))
        // The stale build must not have frozen itself back in after the
        // invalidate: nothing to reuse, so the next run reads memory again.
        #expect(await agent.frozenRunContext == nil)
        memory.agent = nil   // run 2 must not invalidate itself again
        _ = try await agent.run("two")
        #expect(Self.systems(provider)[1].contains("RUN 2"))
        #expect(await agent.frozenRunContext != nil)
    }

    /// `restoreRunContext` with freeze off is a no-op: nothing ever reads
    /// `frozenRunContext` when `config.freezeRunContext` is false (it is an
    /// immutable `let`, so it can't turn on later), so storing a value there
    /// would be a context no run ever uses, silently kept forever by an app
    /// that persists `agent.frozenRunContext` after each run.
    @Test func restoreRunContextIsANoOpWithFreezeOff() async throws {
        let provider = ScriptedProvider(turns: [])
        let agent = try await Self.agent(freeze: false, provider: provider, memory: TextMemoryStore("MEMORY"))
        let saved = FrozenRunContext(baseDigest: "whatever", memory: "OTHER", runContext: "OTHER", skillIndex: "")
        try await agent.restoreRunContext(saved)
        #expect(await agent.frozenRunContext == nil)
        _ = try await agent.run("one")
        #expect(await agent.frozenRunContext == nil)
        #expect(!Self.systems(provider)[0].contains("OTHER"))
    }

    /// The app persists `FrozenRunContext` as JSON (`chat-prompts/*.json`).
    /// Renaming a property would silently fail every decode on a relaunch
    /// (the app would just rebuild fresh, never raising an error) — so the
    /// wire shape is pinned here, not left to the synthesized Codable
    /// conformance drifting unnoticed.
    @Test func codableKeysArePinned() throws {
        let json = #"{"baseDigest":"D","memory":"M","runContext":"R","skillIndex":"S"}"#
        let decoded = try JSONDecoder().decode(FrozenRunContext.self, from: Data(json.utf8))
        #expect(decoded == FrozenRunContext(baseDigest: "D", memory: "M", runContext: "R", skillIndex: "S"))
        let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: String]
        #expect(reencoded == ["baseDigest": "D", "memory": "M", "runContext": "R", "skillIndex": "S"])
    }

    /// With freeze on, calling `load_tools` mid-chat must not change the
    /// frozen system prompt: the loaded tools reach the model only through
    /// the tools array, never through the prompt text.
    @Test func loadToolsMidChatLeavesTheFrozenSystemPromptUnchanged() async throws {
        let browser = DeferredToolGroup(id: "browser", description: "control a browser",
                                        toolNames: ["browser_open"])
        let provider = ScriptedProvider(turns: [
            [LLMToolCall(id: "l1", name: "load_tools", arguments: #"{"groups":["browser"]}"#)], []
        ])
        let agent = Agent(config: AgentConfig(provider: provider, model: "mock", systemPrompt: "BASE",
                                              maxTurns: 6, toolGroups: [browser], freezeRunContext: true))
        try await agent.setMemoryStore(TextMemoryStore("MEMORY"))
        _ = try await agent.run("open it")
        let systems = Self.systems(provider)
        #expect(systems.count == 2)
        #expect(systems[0] == systems[1], "load_tools must not change the frozen prompt mid-run")
        let frozenAfterLoad = try #require(await agent.frozenRunContext)
        _ = try await agent.run("again")
        #expect(Self.systems(provider)[2] == systems[0], "run 2 still sends the same frozen prompt")
        #expect(await agent.frozenRunContext == frozenAfterLoad, "the frozen copy was not rebuilt")
    }

    /// Exactly today's assembly: base, memory, per-run block (blank line
    /// between each), then the tool line, the skill index, the group index.
    @Test func theSystemPromptKeepsItsOrderAndSeparators() {
        let all = FrozenRunContext(baseDigest: "d", memory: "M", runContext: "R", skillIndex: "\n\nS")
        #expect(Agent.renderSystemPrompt(base: "B", parts: all, toolLine: "\nT", groupIndex: "\n\nG")
                == "B\n\nM\n\nR\nT\n\nS\n\nG")
        let memoryOnly = FrozenRunContext(baseDigest: "d", memory: "M", runContext: "", skillIndex: "")
        #expect(Agent.renderSystemPrompt(base: "", parts: memoryOnly, toolLine: "", groupIndex: "") == "M")
        let none = FrozenRunContext(baseDigest: "d", memory: "", runContext: "", skillIndex: "")
        #expect(Agent.renderSystemPrompt(base: "B", parts: none, toolLine: "\nT", groupIndex: "") == "B\nT")
    }
}

extension FrozenRunContextTests {
    /// A child's prompt is new on every spawn and carries memory as it is
    /// then — a parent's frozen context does not hold it back.
    @Test func aSubAgentReadsCurrentMemoryAndNeverFreezes() async throws {
        let memory = TextMemoryStore("MEMORY v1")
        let parent = Agent(config: AgentConfig(provider: ScriptedProvider(turns: []), model: "mock",
                                               systemPrompt: "BASE", maxTurns: 1, freezeRunContext: true))
        try await parent.setMemoryStore(memory)
        _ = try await parent.run("one")
        memory.text = "MEMORY v2"
        let child = await SubAgentSpawner(parent: parent).makeChild()
        #expect(child.config.systemPrompt?.contains("MEMORY v2") == true)
        #expect(child.config.freezeRunContext == false)
    }
}
