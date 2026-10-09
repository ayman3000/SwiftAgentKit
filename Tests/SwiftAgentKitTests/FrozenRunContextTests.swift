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
