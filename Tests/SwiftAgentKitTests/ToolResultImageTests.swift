import Testing
import Foundation
import LLMProviderKit
@testable import SwiftAgentKit

/// A tool result can carry images, they survive Codable, and they flow through
/// `toLLMMessages()` onto the `.tool` LLM message so a vision model sees them.
struct ToolResultImageTests {

    private var sampleImage: LLMImage {
        LLMImage(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png")   // "‰PNG"
    }

    @Test func imagesSurviveCodableRoundTrip() throws {
        let result = AgentToolResult.success(
            toolCallId: "tu_1", toolName: "take_snapshot",
            result: "captured", images: [sampleImage])
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(AgentToolResult.self, from: data)
        #expect(decoded.images == [sampleImage])
        #expect(decoded.result == "captured")
    }

    @Test func toLLMMessagesForwardsImagesOntoToolMessage() {
        let msg = AgentMessage.tool(results: [
            .success(toolCallId: "tu_1", toolName: "take_snapshot",
                     result: "captured", images: [sampleImage])
        ])
        let llm = msg.toLLMMessages()
        #expect(llm.count == 1)
        #expect(llm[0].role == .tool)
        #expect(llm[0].toolCallId == "tu_1")
        #expect(llm[0].images == [sampleImage])
    }

    @Test func textOnlyResultCarriesNoImages() {
        let msg = AgentMessage.tool(results: [
            .success(toolCallId: "tu_2", toolName: "noop", result: "ok")
        ])
        let llm = msg.toLLMMessages()
        #expect(llm[0].images.isEmpty)
    }
}
