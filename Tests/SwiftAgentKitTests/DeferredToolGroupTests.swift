import Foundation
import LLMProviderKit
@testable import SwiftAgentKit
import Testing

// Tools of a deferred group (an MCP server, say) are not sent until the model
// loads the group. chrome-devtools alone was 30 tools / 6,769 tokens on every
// call while used in 2–4% of turns.

private final class ScriptedToolProvider: LLMProvider, @unchecked Sendable {
    static let name = "scripted-tools"
    let configuration = LLMProviderConfiguration(name: ScriptedToolProvider.name, baseURL: URL(string: "inproc://x")!)
    private let lock = NSLock()
    private var script: [LLMResponse.Kind]
    private(set) var toolNamesPerCall: [[String]] = []
    private(set) var systemPerCall: [String] = []
    init(_ script: [LLMResponse.Kind]) { self.script = script }
    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let next: LLMResponse.Kind = lock.withLock {
            toolNamesPerCall.append(request.tools.map(\.name))
            systemPerCall.append(request.messages.first { $0.role == .system }?.content ?? "")
            return script.isEmpty ? .text("done") : script.removeFirst()
        }
        switch next {
        case .text(let t): return LLMResponse(text: t, finishReason: .stop, request: request, providerName: Self.name)
        case .call(let name, let args):
            return LLMResponse(text: "", finishReason: .toolCalls,
                               toolCalls: [LLMToolCall(id: UUID().uuidString, name: name, arguments: args)],
                               request: request, providerName: Self.name)
        }
    }
}

extension LLMResponse { enum Kind { case text(String), call(String, String) } }

private final class RunCounter: @unchecked Sendable { var runs = 0 }

private struct NamedTool: AgentTool {
    let name: String
    let counter: RunCounter
    var description: String { "tool \(name)" }
    let parameters = ToolParameters(properties: [:], required: [])
    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        counter.runs += 1
        return .success(toolCallId: "", toolName: name, result: "\(name) ran")
    }
}

struct DeferredToolGroupTests {
    private let browser = DeferredToolGroup(id: "browser", description: "control a browser",
                                            toolNames: ["browser_open", "browser_click"])

    private func agent(_ provider: ScriptedToolProvider, groups: [DeferredToolGroup], counter: RunCounter) async -> Agent {
        let a = Agent(config: AgentConfig(provider: provider, model: "m", maxTurns: 6, toolGroups: groups))
        await a.register(EchoTool())
        await a.register(NamedTool(name: "browser_open", counter: counter))
        await a.register(NamedTool(name: "browser_click", counter: counter))
        return a
    }

    @Test func toolsOfAnUnloadedGroupAreNotSent() async throws {
        let p = ScriptedToolProvider([.text("hi")])
        _ = try await agent(p, groups: [browser], counter: RunCounter()).run("hello")
        let first = try #require(p.toolNamesPerCall.first)
        #expect(!first.contains("browser_open") && !first.contains("browser_click"), "\(first)")
        #expect(first.contains("load_tools") && first.contains("echo"))
        #expect(p.systemPerCall.first?.contains("- browser: control a browser (2 tools)") == true)
    }

    @Test func loadingAGroupAddsItsToolsAtTheEndOnTheNextCall() async throws {
        let counter = RunCounter()
        let p = ScriptedToolProvider([.call("load_tools", #"{"groups":["browser"]}"#),
                                      .call("browser_open", "{}"), .text("done")])
        _ = try await agent(p, groups: [browser], counter: counter).run("open it")
        #expect(p.toolNamesPerCall.count == 3)
        #expect(Array(p.toolNamesPerCall[1].suffix(2)) == ["browser_open", "browser_click"], "\(p.toolNamesPerCall[1])")
        #expect(Array(p.toolNamesPerCall[1].dropLast(2)) == p.toolNamesPerCall[0], "tools before the loaded ones must not move")
        #expect(counter.runs == 1)
    }

    @Test func theIndexDoesNotChangeWhenAGroupLoads() async throws {
        let p = ScriptedToolProvider([.call("load_tools", #"{"groups":["browser"]}"#), .text("done")])
        _ = try await agent(p, groups: [browser], counter: RunCounter()).run("go")
        #expect(p.systemPerCall.count == 2)
        #expect(p.systemPerCall[0] == p.systemPerCall[1])
    }

    @Test func callingAnUnloadedToolLoadsItsGroupAndAsksToRetry() async throws {
        let counter = RunCounter()
        let p = ScriptedToolProvider([.call("browser_open", "{}"), .call("browser_open", "{}"), .text("done")])
        _ = try await agent(p, groups: [browser], counter: counter).run("open it")
        #expect(counter.runs == 1, "the blind first call must not run; the retry does")
        #expect(p.toolNamesPerCall[1].contains("browser_open"), "the group is loaded for the next call")
    }

    @Test func anAlwaysLoadedGroupIsSentFromTheStartAndNotIndexed() async throws {
        let always = DeferredToolGroup(id: "browser", description: "control a browser",
                                       toolNames: ["browser_open", "browser_click"], alwaysLoaded: true)
        let p = ScriptedToolProvider([.text("hi")])
        _ = try await agent(p, groups: [always], counter: RunCounter()).run("hello")
        #expect(p.toolNamesPerCall[0].contains("browser_open"))
        #expect(!p.toolNamesPerCall[0].contains("load_tools"), "nothing deferred, nothing to load")
        #expect(p.systemPerCall[0].contains("- browser:") == false)
    }

    @Test func loadingAnUnknownGroupSaysWhatExists() async {
        let a = Agent(config: AgentConfig(provider: ScriptedToolProvider([]), model: "m", toolGroups: [browser]))
        let result = await a.loadToolGroups(["nope"])
        #expect(result.contains("nope") && result.contains("browser"), "\(result)")
    }

    @Test func aSubAgentStartsWithItsParentsLoadedGroups() async {
        let parent = Agent(config: AgentConfig(provider: ScriptedToolProvider([]), model: "m", toolGroups: [browser]))
        _ = await parent.loadToolGroups(["browser"])
        let child = await SubAgentSpawner(parent: parent).makeChild()
        #expect(await child.loadedToolGroupIDs == ["browser"])
    }

    @Test func loadToolsIsReadOnlySoItBatchesWithReads() async {
        let a = Agent(config: AgentConfig(provider: ScriptedToolProvider([]), model: "m", toolGroups: [browser]))
        await a.flushRegistrations()
        let tool = await a.tools.tool(named: "load_tools")
        #expect(tool?.isReadOnly == true)
    }
}
