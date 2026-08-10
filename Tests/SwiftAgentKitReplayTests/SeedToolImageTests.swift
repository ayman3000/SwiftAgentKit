import Testing
import Foundation
import LLMProviderKit
import SwiftAgentKit
@testable import SwiftAgentKitReplay

/// A stand-in for an MCP screenshot tool: returns an image.
private struct ScreenshotTool: AgentTool {
    let name = "screenshot"
    let description = "Returns an image."
    let parameters = ToolParameters.empty
    func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        .success(
            toolCallId: "",
            toolName: name,
            result: "captured",
            images: [LLMImage(data: Data([0xAB, 0xCD]), mimeType: "image/png")]
        )
    }
}

@Test func toolResultImageReachesTheNextRequest() async throws {
    let scenario = try Scenario.load(
        from: fixturesDirectory().appendingPathComponent("tool-image-survives.json"))
    let run = ReplayRun(scenario: scenario, tools: [ScreenshotTool()])

    _ = try await run.run("Screenshot the page and describe it.")

    #expect(run.toolCallNames == ["screenshot"])
    // Request #2 (index 1) is the turn AFTER the tool ran. Its .tool message
    // must still carry the image the tool returned — this is what stamp dropped.
    let secondRequest = try #require(run.capturedRequests.dropFirst().first)
    let toolMessageWithImage = secondRequest.messages.contains { msg in
        msg.role == .tool && !msg.images.isEmpty
    }
    #expect(toolMessageWithImage, "the tool-result image did not reach the next LLM request")
}
