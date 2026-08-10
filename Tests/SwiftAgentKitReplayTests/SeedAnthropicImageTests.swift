import Testing
import Foundation
import LLMProviderKit
import LLMProviderKitAnthropic
@testable import SwiftAgentKitReplay

private func anthropicProvider() -> AnthropicProvider {
    AnthropicProvider(configuration: LLMProviderConfiguration(
        name: "anthropic",
        baseURL: URL(string: "https://example.invalid")!,
        apiKey: "TEST-KEY-NOT-REAL",
        defaultModel: "claude-sonnet-4-6"))
}

/// A conversation ending in a tool result that carries an image.
private func toolImageRequest() -> LLMRequest {
    let toolMessage = LLMMessage(
        role: .tool,
        content: "screenshot captured",
        images: [LLMImage(data: Data([0x01, 0x02, 0x03]), mimeType: "image/png")],
        toolCallId: "call_shot_1")
    return LLMRequest(
        model: "claude-sonnet-4-6",
        messages: [
            .user("screenshot the page"),
            .assistant(content: "", toolCalls: [LLMToolCall(id: "call_shot_1", name: "screenshot", arguments: "{}")]),
            toolMessage,
        ])
}

@Test func anthropicPlacesToolImageInsideToolResultContent() throws {
    let provider = anthropicProvider()
    let request = toolImageRequest()

    let golden = fixturesDirectory().appendingPathComponent("wire/anthropic-tool-image.json")
    try assertWireSnapshot(request, provider: provider, goldenPath: golden)

    // Intent invariant: the body carries an image block alongside the tool_result.
    let body = try provider.prepareRequest(request, stream: false).httpBody!
    let json = try canonicalJSONString(from: body)
    #expect(json.contains("tool_result"))
    #expect(json.contains("\"type\" : \"image\""))
    #expect(json.contains("base64"))
}
