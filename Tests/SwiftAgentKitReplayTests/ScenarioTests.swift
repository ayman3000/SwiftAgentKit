import Testing
import Foundation
import LLMProviderKit
@testable import SwiftAgentKitReplay

@Test func scriptedTurnRoundTripsThroughJSON() throws {
    let turn = ScriptedTurn(
        text: "hello",
        toolCalls: [LLMToolCall(id: "c1", name: "echo", arguments: "{}")]
    )
    let scenario = Scenario(name: "unit", turns: [turn])
    let data = try JSONEncoder().encode(scenario)
    let decoded = try JSONDecoder().decode(Scenario.self, from: data)
    #expect(decoded == scenario)
    #expect(decoded.turns[0].toolCalls[0].name == "echo")
}

@Test func scenarioLoadsFromFixtureFile() throws {
    let url = fixturesDirectory().appendingPathComponent("say-hi.json")
    let scenario = try Scenario.load(from: url)
    #expect(scenario.name == "say-hi")
    #expect(scenario.turns.count == 1)
    #expect(scenario.turns[0].text == "Hi there!")
    #expect(scenario.turns[0].toolCalls.isEmpty)
}
