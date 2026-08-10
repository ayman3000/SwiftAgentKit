import Testing
import Foundation
import LLMProviderKit
@testable import SwiftAgentKitReplay

/// A canned "real" provider so the test stays offline: returns fixed responses.
private final class StubProvider: LLMProvider, @unchecked Sendable {
    static let name = "stub"
    let configuration = LLMProviderConfiguration(name: "stub", baseURL: URL(string: "stub://x")!)
    private let replies: [String]
    private let lock = NSLock()
    private var i = 0
    init(replies: [String]) { self.replies = replies }
    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let text = lock.withLock { () -> String in let t = replies[i]; i += 1; return t }
        return LLMResponse(text: text, request: request, providerName: Self.name)
    }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Test func recordingProviderCapturesResponsesReplayableByReplayProvider() async throws {
    let recorder = RecordingProvider(wrapping: StubProvider(replies: ["one", "two"]), name: "rec")
    _ = try await recorder.complete(LLMRequest(model: "m", messages: [.user("a")]))
    _ = try await recorder.complete(LLMRequest(model: "m", messages: [.user("b")]))

    let scenario = recorder.scenario(named: "captured")
    #expect(scenario.turns.map(\.text) == ["one", "two"])

    // The captured scenario replays to the same responses.
    let replay = ReplayProvider(scenario: scenario)
    let r1 = try await replay.complete(LLMRequest(model: "m", messages: [.user("x")]))
    let r2 = try await replay.complete(LLMRequest(model: "m", messages: [.user("y")]))
    #expect(r1.text == "one")
    #expect(r2.text == "two")
}
