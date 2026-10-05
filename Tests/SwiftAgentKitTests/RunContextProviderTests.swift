import Testing
import Foundation
import LLMProviderKit
@testable import SwiftAgentKit

private final class RecordingProvider: LLMProvider, @unchecked Sendable {
    static let name = "recording"
    let configuration = LLMProviderConfiguration(
        name: name, baseURL: URL(string: "inprocess://recording")!, defaultModel: "mock")
    private let lock = NSLock()
    private var _seen: [LLMRequest] = []
    var systems: [String] {
        lock.withLock { _seen.map { $0.messages.first { $0.role == .system }?.content ?? "" } }
    }
    private func record(_ request: LLMRequest) { lock.withLock { _seen.append(request) } }
    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        record(request)
        return LLMResponse(text: "done", finishReason: .stop, request: request, providerName: Self.name)
    }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        record(request)
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("done"))
            continuation.yield(.finish(reason: .stop, usage: nil))
            continuation.finish()
        }
    }
}

private struct NoopTool: AgentTool {
    let name = "read_thing"
    let description = "reads"
    let parameters = ToolParameters(properties: [:], required: [])
    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        .success(toolCallId: "", toolName: name, result: "")
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [[String]] = []
    func record(_ n: [String]) -> Int { lock.withLock { names.append(n); return names.count } }
    var all: [[String]] { lock.withLock { names } }
}

struct RunContextProviderTests {
    @Test func theProviderIsAskedOnEveryRunWithTheToolNames() async throws {
        let provider = RecordingProvider()
        let agent = Agent(config: AgentConfig(provider: provider, model: "mock", systemPrompt: "BASE", maxTurns: 1))
        await agent.register(NoopTool())
        let calls = Calls()
        try await agent.setRunContextProvider { names in
            let n = calls.record(names)
            return "LESSONS \(n)"
        }
        _ = try await agent.run("one")
        _ = try await agent.run("two")
        let systems = provider.systems
        #expect(systems.first?.contains("BASE\n\nLESSONS 1") == true, "\(systems)")
        #expect(systems.last?.contains("LESSONS 2") == true, "built per run, not once")
        #expect(calls.all.first?.contains("read_thing") == true)
    }

    @Test func anEmptyContextAddsNothing() async throws {
        let provider = RecordingProvider()
        let agent = Agent(config: AgentConfig(provider: provider, model: "mock", systemPrompt: "BASE", maxTurns: 1))
        try await agent.setRunContextProvider { _ in "" }
        _ = try await agent.run("one")
        #expect(provider.systems.first?.hasPrefix("BASE") == true)
        #expect(provider.systems.first?.contains("BASE\n\n\n") == false)
    }
}
