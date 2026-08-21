import Testing
import Foundation
import LLMProviderKit
import SwiftAgentKit
@testable import SwiftAgentKitReplay

/// Regression: the streaming path used to DROP the provider's token usage
/// (`case .finish(let reason, _)`), synthesizing the final response with
/// `usage: nil` — which forced cost/context onto a local estimate. The
/// provider reports real usage on the final `.finish` chunk; it must survive
/// onto the response the agent emits.
@Test func streamingResponseCarriesProviderUsage() async throws {
    let scenario = Scenario(name: "usage", turns: [
        ScriptedTurn(
            text: "Done.",
            finishReason: .stop,
            usage: LLMUsage(promptTokens: 123, completionTokens: 45, totalTokens: 168)
        ),
    ])
    let run = ReplayRun(scenario: scenario)
    _ = try await run.runStreaming("hi")

    let usage: AgentTokenUsage? = run.events.compactMap { event in
        if case .llmCallCompleted(_, let response) = event { return response.usage }
        return nil
    }.first ?? nil

    #expect(usage?.promptTokens == 123)
    #expect(usage?.completionTokens == 45)
}
