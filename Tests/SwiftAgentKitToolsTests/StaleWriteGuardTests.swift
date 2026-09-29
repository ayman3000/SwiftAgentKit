import Testing
import Foundation
import SwiftAgentKit
@testable import SwiftAgentKitTools

/// Parallel sub-agents (2026-09-29): an agent may not overwrite a file that
/// changed since it last saw it — another agent (or the user) changed it, and
/// a whole-file write would silently throw that work away.
struct StaleWriteGuardTests {

    private func tempFile(_ text: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-\(UUID().uuidString).md").path
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func read(_ path: String) async throws -> AgentToolResult {
        try await FileReadTool().execute(parameters: ["path": path])
    }

    private func write(_ path: String, _ content: String) async throws -> AgentToolResult {
        try await FileWriteTool().execute(parameters: ["path": path, "content": content])
    }

    @Test func aFileChangedSinceThisAgentReadItIsNotOverwritten() async throws {
        let path = try tempFile("one\n")
        try await FileStateRegistry.$currentAgent.withValue(UUID()) { () async throws in
            _ = try await read(path)
            try "changed by someone else\n".write(toFile: path, atomically: true, encoding: .utf8)
            let result = try await write(path, "mine\n")
            #expect(result.isError)
            #expect(result.result.contains("changed since you last read it"))
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "changed by someone else\n")
    }

    @Test func readingItAgainAllowsTheWrite() async throws {
        let path = try tempFile("one\n")
        try await FileStateRegistry.$currentAgent.withValue(UUID()) { () async throws in
            _ = try await read(path)
            try "changed by someone else\n".write(toFile: path, atomically: true, encoding: .utf8)
            _ = try await read(path)
            #expect(try await write(path, "mine\n").isError == false)
        }
    }

    @Test func anAgentMayRewriteWhatItWroteItself() async throws {
        let path = try tempFile("one\n")
        try await FileStateRegistry.$currentAgent.withValue(UUID()) { () async throws in
            _ = try await read(path)
            #expect(try await write(path, "two\n").isError == false)
            #expect(try await write(path, "three\n").isError == false)
        }
    }

    @Test func aFileThisAgentNeverReadCanBeWritten() async throws {
        let path = try tempFile("one\n")
        try await FileStateRegistry.$currentAgent.withValue(UUID()) { () async throws in
            #expect(try await write(path, "two\n").isError == false)
        }
    }

    @Test func anotherAgentsWriteCountsAsAChange() async throws {
        let path = try tempFile("one\n")
        let parent = UUID(), child = UUID()
        try await FileStateRegistry.$currentAgent.withValue(parent) { _ = try await read(path) }
        try await FileStateRegistry.$currentAgent.withValue(child) { () async throws in
            _ = try await read(path)
            #expect(try await write(path, "child's version\n").isError == false)
        }
        try await FileStateRegistry.$currentAgent.withValue(parent) { () async throws in
            #expect(try await write(path, "parent's version\n").isError)
        }
    }

    @Test func anAgentsOwnEditKeepsItsViewCurrent() async throws {
        let path = try tempFile("alpha\nbeta\n")
        try await FileStateRegistry.$currentAgent.withValue(UUID()) { () async throws in
            _ = try await read(path)
            let edit = try await EditFileTool().execute(
                parameters: ["path": path, "old_text": "beta", "new_text": "gamma"])
            #expect(edit.isError == false)
            #expect(try await write(path, "delta\n").isError == false)
        }
    }

    @Test func appendingIsNeverRefused() async throws {
        let path = try tempFile("one\n")
        try await FileStateRegistry.$currentAgent.withValue(UUID()) { () async throws in
            _ = try await read(path)
            try "changed\n".write(toFile: path, atomically: true, encoding: .utf8)
            let result = try await FileWriteTool().execute(
                parameters: ["path": path, "content": "more\n", "append": true])
            #expect(result.isError == false)
        }
    }

    @Test func outsideAnAgentRunNothingIsGuarded() async throws {
        let path = try tempFile("one\n")
        _ = try await read(path)
        try "changed\n".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(try await write(path, "mine\n").isError == false)
    }
}
