import Testing
import Foundation
import LLMProviderKit
import LLMProviderKitGemini
@testable import SwiftAgentKitReplay

@Test func canonicalJSONSortsKeysStably() throws {
    let a = try canonicalJSONString(from: Data(#"{"b":1,"a":2}"#.utf8))
    let b = try canonicalJSONString(from: Data(#"{"a":2,"b":1}"#.utf8))
    #expect(a == b)
    #expect(a.contains("\"a\""))
}

@Test func canonicalJSONThrowsOnNonJSON() {
    #expect(throws: (any Error).self) {
        _ = try canonicalJSONString(from: Data("not json".utf8))
    }
}

@Test func assertWireSnapshotFailsWhenGoldenMissingAndNotUpdating() throws {
    let provider = GeminiProvider(configuration: LLMProviderConfiguration(
        name: "gemini",
        baseURL: URL(string: "https://example.invalid/v1beta/models")!,
        apiKey: "TEST-KEY-NOT-REAL",
        defaultModel: "gemini-2.5-flash"))
    let request = LLMRequest(
        model: "gemini-2.5-flash",
        messages: [.user("hello")])

    let tempPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("sak-wire-missing-\(UUID().uuidString).json")

    // The golden does not exist and update is false — must throw missingGolden.
    #expect(throws: WireSnapshotError.self) {
        try assertWireSnapshot(request, provider: provider, goldenPath: tempPath, update: false)
    }

    // Confirm no file was written at the temp path.
    #expect(!FileManager.default.fileExists(atPath: tempPath.path))
}
