import Testing
import Foundation
import LLMProviderKit
import SwiftAgentKit
@testable import SwiftAgentKitReplay

@Test func replayRunReturnsScriptedFinalAnswerWithNoTools() async throws {
    let scenario = Scenario(name: "answer", turns: [
        ScriptedTurn(text: "The answer is 42.", finishReason: .stop),
    ])
    let run = ReplayRun(scenario: scenario)
    let answer = try await run.run("What is the answer?")

    #expect(answer.contains("42"))
    #expect(run.toolCallNames.isEmpty)
    #expect(run.capturedRequests.count == 1)
}
