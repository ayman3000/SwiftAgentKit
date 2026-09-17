import Testing
import Foundation
@testable import SwiftAgentKit

/// Billed outside the machine: autonomy must still ask.
private struct CostlyTool: AgentTool {
    let name = "costly"
    let description = "spends money"
    let parameters = ToolParameters(properties: [:], required: [])
    var requiresConfirmation: Bool { true }
    var requiresConfirmationEvenWhenAutonomous: Bool { true }
    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        .success(toolCallId: "", toolName: name, result: "spent")
    }
}

/// Local and recoverable: autonomy may waive it, as it always has.
private struct LocalTool: AgentTool {
    let name = "local"
    let description = "writes a file"
    let parameters = ToolParameters(properties: [:], required: [])
    var requiresConfirmation: Bool { true }
    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        .success(toolCallId: "", toolName: name, result: "wrote")
    }
}

@Suite struct AutonomyConfirmationTests {

    private func run(_ tool: any AgentTool, autonomous: Bool,
                     approve: Bool?) async -> AgentToolResult {
        let registry = ToolRegistry()
        await registry.register(tool)
        let dispatcher = ToolDispatcher(registry: registry)
        await dispatcher.setAutonomousMode(autonomous)
        var callbacks = AgentCallbacks()
        if let approve {
            callbacks.onToolConfirmation = { _, _ in approve }
        }
        let results = await dispatcher.dispatch(
            calls: [AgentToolCall(name: tool.name)],
            state: AgentState(), callbacks: callbacks, observer: nil)
        return results[0]
    }

    @Test func autonomyDoesNotWaiveACostlyToolsConfirmation() async {
        // Denied under autonomy — the gate still ran.
        let denied = await run(CostlyTool(), autonomous: true, approve: false)
        #expect(denied.isError)
        #expect(!denied.result.contains("spent"))

        // And approving under autonomy lets it through.
        let approved = await run(CostlyTool(), autonomous: true, approve: true)
        #expect(approved.isError == false)
        #expect(approved.result.contains("spent"))
    }

    /// With no handler at all, a costly tool must fail CLOSED even in
    /// autonomous mode — the previous behaviour would have run it.
    @Test func aCostlyToolFailsClosedWhenNobodyCanBeAsked() async {
        let result = await run(CostlyTool(), autonomous: true, approve: nil)
        #expect(result.isError)
        #expect(!result.result.contains("spent"))
    }

    @Test func autonomyStillWaivesOrdinaryConfirmations() async {
        // Unchanged behaviour for every existing tool: no handler, runs anyway.
        let result = await run(LocalTool(), autonomous: true, approve: nil)
        #expect(result.isError == false)
        #expect(result.result.contains("wrote"))
    }

    @Test func withoutAutonomyBothToolsAreStillGated() async {
        #expect(await run(CostlyTool(), autonomous: false, approve: false).isError)
        #expect(await run(LocalTool(), autonomous: false, approve: false).isError)
        #expect(await run(LocalTool(), autonomous: false, approve: true).isError == false)
    }
}
