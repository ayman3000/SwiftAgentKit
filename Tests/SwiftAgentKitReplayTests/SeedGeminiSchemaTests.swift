import Testing
import Foundation
import LLMProviderKit
import LLMProviderKitGemini
@testable import SwiftAgentKitReplay

private func geminiProvider() -> GeminiProvider {
    GeminiProvider(configuration: LLMProviderConfiguration(
        name: "gemini",
        baseURL: URL(string: "https://example.invalid/v1beta/models")!,
        apiKey: "TEST-KEY-NOT-REAL",
        defaultModel: "gemini-2.5-flash"))
}

/// An MCP-style tool whose `tags` array declares no `items` and carries the
/// non-standard `itemsType`/`defaultValue` keys Gemini rejects.
private func badSchemaRequest() -> LLMRequest {
    let params: [String: Any] = [
        "type": "object",
        "properties": [
            "tags": ["type": "array", "itemsType": "string"],
            "count": ["type": "integer", "defaultValue": 1],
        ],
        "required": ["tags"],
    ]
    return LLMRequest(
        model: "gemini-2.5-flash",
        messages: [.user("call the tool")],
        tools: [LLMToolDefinition(name: "edit", description: "Edit op", parameters: params)])
}

@Test func geminiToolSchemaIsSanitizedInWireBody() throws {
    let provider = geminiProvider()
    let request = badSchemaRequest()

    // 1) Golden snapshot — locks the exact sanitized body.
    let golden = fixturesDirectory().appendingPathComponent("wire/gemini-mcp-schema.json")
    try assertWireSnapshot(request, provider: provider, goldenPath: golden)

    // 2) Explicit invariants — independent of the golden, so intent is documented.
    let body = try provider.prepareRequest(request, stream: false).httpBody!
    let json = try canonicalJSONString(from: body)
    #expect(!json.contains("itemsType"), "non-standard key itemsType must be stripped")
    #expect(!json.contains("defaultValue"), "non-standard key defaultValue must be stripped")
    #expect(json.contains("\"items\""), "array params must gain an items schema")
}
