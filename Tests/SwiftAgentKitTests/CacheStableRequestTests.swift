import Testing
import Foundation
import LLMProviderKit
import LLMProviderKitOpenAI
@testable import SwiftAgentKit

/// Prompt caching reuses the longest identical start of a request. These pin
/// that SwiftAgentKit hands a provider the same bytes for the same history on
/// every call.
struct CacheStableRequestTests {
    /// A call as a provider returns it: arguments parsed by JSONSerialization,
    /// so every number is an NSNumber.
    static func parsedCall(_ json: String, id: String = "call_1", name: String = "edit_file") -> AgentToolCall {
        let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        return AgentToolCall(id: id, name: name, parameters: object.mapValues { AnyCodable($0) })
    }

    @Test func aReplayedCallIsTheSameBytesEveryTime() {
        let call = Self.parsedCall(
            #"{"path":"/tmp/a.swift","old_text":"x","new_text":"y","replace_all":false,"options":{"b":1,"a":2,"c":[1,2]}}"#)
        let message = AgentMessage.assistant(content: "", toolCalls: [call])
        var seen = Set<String>()
        var noise: [[Int]] = []
        for i in 0..<200 {
            noise.append([Int](repeating: i, count: 1 + (i * 37) % 257))
            if noise.count > 16 { noise.removeFirst(8) }
            seen.insert(message.toLLMMessage().toolCalls?.first?.arguments ?? "")
        }
        #expect(seen.count == 1)
        #expect(seen.first
                == #"{"new_text":"y","old_text":"x","options":{"a":2,"b":1,"c":[1,2]},"path":"\/tmp\/a.swift","replace_all":false}"#)
    }

    /// JSONSerialization gives `1` as an NSNumber that also casts to Bool:
    /// replayed, the call said `true` where the model wrote `1`.
    @Test func numbersAreReplayedAsTheModelWroteThem() {
        let call = Self.parsedCall(#"{"count":1,"zero":0,"flag":true,"off":false,"ratio":2.5,"whole":1.0}"#)
        let arguments = AgentMessage.assistant(content: "", toolCalls: [call]).toLLMMessage().toolCalls?.first?.arguments
        #expect(arguments == #"{"count":1,"flag":true,"off":false,"ratio":2.5,"whole":1,"zero":0}"#)
    }
}

/// Answers from a script: each turn is the tool calls to return, or `[]` for
/// a plain "done". Records every request it was sent.
final class ScriptedProvider: LLMProvider, @unchecked Sendable {
    static let name = "scripted"
    let configuration = LLMProviderConfiguration(
        name: name, baseURL: URL(string: "inprocess://scripted")!, defaultModel: "mock")
    private let lock = NSLock()
    private var turns: [[LLMToolCall]]
    private var requests: [LLMRequest] = []

    init(turns: [[LLMToolCall]]) { self.turns = turns }

    var captured: [LLMRequest] { lock.withLock { requests } }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let calls: [LLMToolCall] = lock.withLock {
            requests.append(request)
            return turns.isEmpty ? [] : turns.removeFirst()
        }
        if calls.isEmpty {
            return LLMResponse(text: "done", finishReason: .stop, request: request, providerName: Self.name)
        }
        return LLMResponse(text: "", finishReason: .toolCalls, toolCalls: calls,
                           request: request, providerName: Self.name)
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text("done"))
            continuation.yield(.finish(reason: .stop, usage: nil))
            continuation.finish()
        }
    }
}

private struct SortTestTool: AgentTool {
    let name: String
    var description: String { "The \(name) tool." }
    let parameters = ToolParameters(properties: [:], required: [])
    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        .success(toolCallId: "", toolName: name, result: "ok")
    }
}

private struct NamedTool: AgentTool {
    let name: String
    let description: String
    let parameters = ToolParameters(properties: [:], required: [])
    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        .success(toolCallId: "", toolName: name, result: description)
    }
}

private struct EditTool: AgentTool {
    let name = "edit_file"
    let description = "Edit a file."
    let parameters = ToolParameters(properties: [
        "path": ToolParameterProperty(type: "string", description: "file"),
        "old_text": ToolParameterProperty(type: "string", description: "old"),
        "new_text": ToolParameterProperty(type: "string", description: "new"),
    ], required: ["path"])
    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        .success(toolCallId: "", toolName: name, result: "edited")
    }
}

private struct ReadTool: AgentTool {
    let name = "read_file"
    let description = "Read a file."
    let parameters = ToolParameters(properties: [
        "path": ToolParameterProperty(type: "string", description: "file"),
        "limit": ToolParameterProperty(type: "integer", description: "characters"),
    ], required: ["path"])
    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        .success(toolCallId: "", toolName: name, result: "file text")
    }
}

/// A skill store whose `loadAll` waits until the test opens it — a slow disk
/// read the test controls.
private final class GatedSkillStore: AgentSkillStore, @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func open() {
        let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { waiting = [] }
            return waiting
        }
        resumed.forEach { $0.resume() }
    }

    func save(_ skill: AgentSkill) async throws {}
    func delete(name: String) async throws {}
    func loadAll() async throws -> [AgentSkill] {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                if isOpen { return true }
                waiting.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
        return []
    }
}

extension CacheStableRequestTests {
    /// What the OpenAI wire would send for `request` (sorted keys since
    /// LLMProviderKit 0.1.0-alpha.39).
    static func wireBody(_ request: LLMRequest) throws -> Data {
        let provider = OpenAIProvider(configuration: OpenAIProvider.openAI(apiKey: "k", model: "mock"))
        return try #require(try provider.prepareRequest(request, stream: false).httpBody)
    }

    /// The same request on the streaming path (`stream: true`).
    static func streamWireBody(_ request: LLMRequest) throws -> Data {
        let provider = OpenAIProvider(configuration: OpenAIProvider.openAI(apiKey: "k", model: "mock"))
        return try #require(try provider.prepareRequest(request, stream: true).httpBody)
    }

    /// The body's bytes up to (not including) the `]` that closes its messages
    /// array — "messages" is the first key of a sorted OpenAI body.
    static func messagesPrefix(_ body: Data) -> Data? {
        let text = String(decoding: body, as: UTF8.self)
        guard text.hasPrefix(#"{"messages":["#), let end = text.range(of: #"],"model":"#) else { return nil }
        return Data(text[..<end.lowerBound].utf8)
    }

    /// The body from its `"tools":` key to the end.
    static func toolsSection(_ body: Data) -> String? {
        let text = String(decoding: body, as: UTF8.self)
        return text.range(of: #""tools":"#).map { String(text[$0.lowerBound...]) }
    }

    @Test func theRegistryListsToolsByName() async {
        let registry = ToolRegistry()
        let names = ["zeta", "alpha", "mu", "beta", "omega", "kappa", "delta", "pi", "eta", "nu", "chi", "rho"]
        for name in names { await registry.register(SortTestTool(name: name)) }
        #expect(await registry.allTools().map(\.name) == names.sorted())
        #expect(await registry.allToolNames() == names.sorted())
    }

    /// Registrations run in call order: an app that replaces a framework tool
    /// (Naseem's learn_skill) gets the same tool on every engine.
    @Test func aLaterRegistrationOfANameAlwaysWins() async {
        for _ in 0..<50 {
            let agent = Agent(config: AgentConfig(provider: ScriptedProvider(turns: []), model: "mock"))
            await agent.register(NamedTool(name: "learn_skill", description: "framework"))
            await agent.registerAll([NamedTool(name: "learn_skill", description: "app")])
            await agent.register(NamedTool(name: "zeta", description: "z"))
            let tools = await agent.registeredTools()
            #expect(tools.first { $0.name == "learn_skill" }?.description == "app")
            #expect(tools.map(\.name) == ["learn_skill", "zeta"])
        }
    }

    /// Naseem's order: `setSkillStore` (the framework's learn_skill, then a
    /// slow skill load), other setup, then the app's own learn_skill. The
    /// app's must win while the earlier work is still running: it waits for
    /// ALL of it, not only for the registration queued right before it.
    @Test func aLaterRegistrationWaitsForEverythingQueuedBeforeIt() async throws {
        let agent = Agent(config: AgentConfig(provider: ScriptedProvider(turns: []), model: "mock"))
        let gate = GatedSkillStore()
        try await agent.setSkillStore(gate)          // learn_skill (framework), use_skill, the gated load
        await agent.register(NamedTool(name: "learn_skill", description: "framework"))
        await agent.setToolContext([:])              // unrelated work that finishes at once
        await agent.register(NamedTool(name: "learn_skill", description: "app"))
        try await Task.sleep(nanoseconds: 100_000_000)
        // The load is still blocked, so nothing queued after it has landed.
        #expect(await agent.tools.allTools().first { $0.name == "learn_skill" }?.description != "app")
        gate.open()
        let tools = await agent.registeredTools()
        #expect(tools.first { $0.name == "learn_skill" }?.description == "app")
    }

    @Test func theDigestIsStableAcrossLaunches() {
        // FNV-1a 64 is unseeded: the same text gives the same digest in any process.
        #expect(PromptDigest.hex("abc") == "e71fa2190541574b")
        #expect(PromptDigest.hex("") == "cbf29ce484222325")
    }

    @Test func theFirstCallOfARunRecordsItsSystemDigest() async throws {
        let provider = ScriptedProvider(turns: [[LLMToolCall(id: "r1", name: "read_file", arguments: #"{"path":"/a"}"#)], []])
        let agent = Agent(config: AgentConfig(provider: provider, model: "mock", systemPrompt: "BASE",
                                              maxTurns: 3, tools: [ReadTool()], loopDetection: nil))
        #expect(await agent.firstRequestSystemDigest == nil)
        _ = try await agent.run("hi")
        let system = provider.captured[0].messages.first { $0.role == .system }?.content ?? ""
        #expect(!system.isEmpty)
        #expect(await agent.firstRequestSystemDigest == PromptDigest.hex(system))
    }

    /// Two runs of one chat, two calls each: every request's wire body starts
    /// with the previous request's messages, byte for byte, and the tool
    /// definitions never change.
    @Test func consecutiveCallsAreAppendOnlyOnTheWire() async throws {
        let provider = ScriptedProvider(turns: [
            [LLMToolCall(id: "e1", name: "edit_file", arguments: #"{"path":"/a","old_text":"x","new_text":"y"}"#)],
            [],
            [LLMToolCall(id: "r1", name: "read_file", arguments: #"{"path":"/a","limit":1}"#)],
            [],
        ])
        let agent = Agent(config: AgentConfig(provider: provider, model: "mock", systemPrompt: "BASE",
                                              maxTurns: 5, tools: [EditTool(), ReadTool()], loopDetection: nil))
        _ = try await agent.run("change x to y in /a")
        _ = try await agent.run("now read /a")

        let bodies = try provider.captured.map(Self.wireBody)
        #expect(bodies.count == 4)
        for (earlier, later) in zip(bodies, bodies.dropFirst()) {
            let prefix = try #require(Self.messagesPrefix(earlier))
            #expect(later.starts(with: prefix), "a later request rewrote an earlier byte")
            #expect(Self.toolsSection(later) == Self.toolsSection(earlier))
        }
        // The replayed `limit` is the integer the model sent, not `true`
        // (inside the body the arguments are a JSON string, so quotes are escaped).
        #expect(String(decoding: bodies[3], as: UTF8.self).contains(#"\"limit\":1,"#))
    }
}

private struct StepTool: AgentTool {
    let name = "run_step"
    let description = "Run one step."
    let parameters = ToolParameters(properties: [
        "n": ToolParameterProperty(type: "integer", description: "step"),
    ], required: ["n"])
    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        .success(toolCallId: "", toolName: name, result: String(repeating: "o", count: 600))
    }
}

extension CacheStableRequestTests {
    static func stepCalls(_ range: ClosedRange<Int>) -> [[LLMToolCall]] {
        range.map { [LLMToolCall(id: "s\($0)", name: "run_step", arguments: #"{"n":\#($0)}"#)] }
    }

    /// For each consecutive pair of requests: nil when the later wire body
    /// starts with the earlier one's messages (append-only); otherwise the
    /// index of the first message that differs.
    static func breakIndices(_ requests: [LLMRequest]) throws -> [Int?] {
        try zip(requests, requests.dropFirst()).map { earlier, later in
            let prefix = try #require(messagesPrefix(try wireBody(earlier)))
            if try wireBody(later).starts(with: prefix) { return nil }
            let pairs = Array(zip(earlier.messages, later.messages))
            return pairs.firstIndex { $0.0 != $0.1 } ?? pairs.count
        }
    }

    /// With a ContextSift batch between two calls, exactly that pair breaks,
    /// and only from the first evicted step on: the system prompt and the
    /// task are the same bytes, and the tool definitions never change.
    @Test func anEvictionBatchBreaksThePrefixOnlyFromItsFirstEvictedStep() async throws {
        let provider = ScriptedProvider(turns: Self.stepCalls(1...6) + [[]])
        // Progress notes off: each is a tail-only break of its own (see
        // aProgressNoteChangesOnlyTheTail), and this test counts batch breaks.
        let agent = Agent(config: AgentConfig(provider: provider, model: "mock", systemPrompt: "BASE",
                                              maxTurns: 8, tools: [StepTool()],
                                              contextManager: ContextManager(inlineBudgetChars: 2_500),
                                              loopDetection: nil, progressNudgeFractions: []))
        _ = try await agent.run("do six steps")

        let requests = provider.captured
        #expect(requests.count == 7)
        let breaks = try Self.breakIndices(requests)
        // Budget ≈ 2,500 − the system prompt (about 470 characters): the fifth
        // call is the first over it, and one batch evicts steps 1–3.
        #expect(breaks.compactMap { $0 } == [2], "one batch, starting at the first step")
        let batch = try #require(breaks.firstIndex { $0 != nil })
        let later = requests[batch + 1]
        #expect(later.messages[2].content.hasPrefix(ContextManager.receiptHeader))
        // Byte level: both bodies start with the same system prompt and task.
        let shared = try #require(Self.messagesPrefix(try Self.wireBody(
            LLMRequest(model: "mock", messages: Array(later.messages.prefix(2)), tools: later.tools))))
        #expect(try Self.wireBody(requests[batch]).starts(with: shared))
        #expect(try Self.wireBody(later).starts(with: shared))
        let tools = try requests.map { Self.toolsSection(try Self.wireBody($0)) }
        #expect(Set(tools.compactMap { $0 }).count == 1)

        // The streaming body (`stream: true`) holds the same promise: append-only
        // between batches, and the batch call keeps the system prompt and task.
        let streamed = try requests.map(Self.streamWireBody)
        for (pair, index) in breaks.enumerated() {
            let prefix = try #require(Self.messagesPrefix(streamed[pair]))
            #expect(streamed[pair + 1].starts(with: prefix) == (index == nil), "streamed pair \(pair)")
        }
        #expect(streamed[batch].starts(with: shared) && streamed[batch + 1].starts(with: shared))
    }

    /// A progress note is for its call only: the next call drops it, so that
    /// pair breaks exactly at the note — the earlier request's last message —
    /// and nothing before it changes. (Default nudges: turns 4 and 6 of 8.)
    @Test func aProgressNoteChangesOnlyTheTail() async throws {
        let provider = ScriptedProvider(turns: Self.stepCalls(1...6) + [[]])
        let agent = Agent(config: AgentConfig(provider: provider, model: "mock", systemPrompt: "BASE",
                                              maxTurns: 8, tools: [StepTool()],
                                              contextManager: ContextManager(inlineBudgetChars: 100_000),
                                              loopDetection: nil))
        _ = try await agent.run("do six steps")
        let requests = provider.captured
        #expect(requests.count == 7)
        let breaks = try Self.breakIndices(requests)
        #expect(breaks.compactMap { $0 }.count == 2)
        for (pair, index) in breaks.enumerated() {
            guard let index else { continue }
            let noted = requests[pair].messages
            #expect(index == noted.count - 1)
            #expect(noted.last?.role == .user)
            #expect(noted.last?.content.hasPrefix("[Progress check]") == true)
        }
    }
}
