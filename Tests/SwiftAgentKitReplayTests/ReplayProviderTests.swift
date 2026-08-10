import Testing
import Foundation
import LLMProviderKit
@testable import SwiftAgentKitReplay

private func request(_ text: String) -> LLMRequest {
    LLMRequest(model: "m", messages: [.user(text)])
}

@Test func replayProviderReturnsScriptedResponsesInOrder() async throws {
    let scenario = Scenario(name: "s", turns: [
        ScriptedTurn(text: "first"),
        ScriptedTurn(text: "second", finishReason: .stop),
    ])
    let provider = ReplayProvider(scenario: scenario)

    let r1 = try await provider.complete(request("a"))
    let r2 = try await provider.complete(request("b"))

    #expect(r1.text == "first")
    #expect(r2.text == "second")
    #expect(r2.finishReason == .stop)
    // The response carries the live request that produced it.
    #expect(r2.request.messages.first?.content == "b")
    #expect(provider.capturedRequests.count == 2)
    #expect(provider.capturedRequests[1].messages.first?.content == "b")
}

@Test func replayProviderThrowsWhenScriptExhausted() async throws {
    let provider = ReplayProvider(scenario: Scenario(name: "s", turns: [ScriptedTurn(text: "only")]))
    _ = try await provider.complete(request("a"))
    await #expect(throws: ReplayError.self) {
        _ = try await provider.complete(request("b"))
    }
}

@Test func replayProviderStreamsScriptedResponseAsChunks() async throws {
    let provider = ReplayProvider(scenario: Scenario(name: "s", turns: [ScriptedTurn(text: "streamed")]))
    var text = ""
    for try await chunk in provider.stream(request("a")) {
        if case .text(let t) = chunk { text += t }
    }
    #expect(text == "streamed")
}
