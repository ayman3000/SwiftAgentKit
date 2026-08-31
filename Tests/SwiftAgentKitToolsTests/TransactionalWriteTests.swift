import Testing
import Foundation
@testable import SwiftAgentKitTools

/// Transactional verified writes (2026-08-31): tool-call content arrives
/// corrupted in transit on some model/provider combos (dropped imports, leaked
/// diff markers, ~6KB truncation — three live incidents). The file tools now
/// verify what landed and ROLL BACK on corruption, so a broken write can never
/// persist — it becomes an immediate, informative retry.
struct TransactionalWriteTests {

    private func tempPath(_ ext: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("txw-\(UUID().uuidString).\(ext)").path
    }

    // MARK: - WriteVerifier (pure-ish)

    @Test func invalidJSONIsCaughtInProcess() async {
        let reason = await WriteVerifier.corruptionReason(
            path: "x.json", content: #"{"a": 1, "b": }"#)
        #expect(reason != nil)
    }

    @Test func validJSONPasses() async {
        let reason = await WriteVerifier.corruptionReason(
            path: "x.json", content: #"{"a": 1}"#)
        #expect(reason == nil)
    }

    @Test func leakedDiffMarkersAreCaught() async {
        // The classic transit-corruption signature: patch-style `+` line
        // prefixes bleeding into write_file content of a code file.
        let corrupted = (1...8).map { "+    import 'dart:async'; // line \($0)" }
            .joined(separator: "\n") + "\nvoid main() {}\n"
        let reason = await WriteVerifier.corruptionReason(path: "x.dart", content: corrupted)
        #expect(reason?.contains("diff") == true)
    }

    @Test func unknownExtensionPasses() async {
        let reason = await WriteVerifier.corruptionReason(
            path: "notes.txt", content: "anything { at all")
        #expect(reason == nil)
    }

    @Test func brokenDartIsCaughtWhenDartAvailable() async {
        guard WriteVerifier.parserAvailable(forExtension: "dart") else { return }  // env-dependent
        let reason = await WriteVerifier.corruptionReason(
            path: "x.dart", content: "void main( { print('missing paren'; }")
        #expect(reason != nil)
    }

    @Test func validDartPassesWhenDartAvailable() async {
        guard WriteVerifier.parserAvailable(forExtension: "dart") else { return }
        let reason = await WriteVerifier.corruptionReason(
            path: "x.dart", content: "void main() { print('ok'); }\n")
        #expect(reason == nil)
    }

    // MARK: - write_file transaction

    @Test func corruptedOverwriteRollsBackOriginal() async throws {
        let path = tempPath("json")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try #"{"good": true}"#.write(toFile: path, atomically: true, encoding: .utf8)

        let tool = FileWriteTool()
        let result = try await tool.execute(parameters: [
            "path": path, "content": #"{"broken": }"#,
        ])
        #expect(result.isError)
        #expect(result.result.contains("unchanged") || result.result.contains("restored"))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == #"{"good": true}"#)
    }

    @Test func corruptedNewFileIsRemoved() async throws {
        let path = tempPath("json")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let tool = FileWriteTool()
        let result = try await tool.execute(parameters: [
            "path": path, "content": #"{"broken": }"#,
        ])
        #expect(result.isError)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func corruptedAppendRestoresOriginal() async throws {
        let path = tempPath("json")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try #"{"a":"#.write(toFile: path, atomically: true, encoding: .utf8)

        let tool = FileWriteTool()
        // Appending garbage leaves whole file invalid → restore the original half.
        let result = try await tool.execute(parameters: [
            "path": path, "content": " }}}}", "append": true,
        ])
        #expect(result.isError)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == #"{"a":"#)
    }

    @Test func validWriteSucceedsUnchangedBehavior() async throws {
        let path = tempPath("json")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let tool = FileWriteTool()
        let result = try await tool.execute(parameters: [
            "path": path, "content": #"{"ok": 1}"#,
        ])
        #expect(!result.isError)
        #expect(result.result.contains("Wrote"))
    }

    // MARK: - apply_patch transaction

    @Test func patchProducingCorruptionRollsBack() async throws {
        let path = tempPath("json")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let original = "{\n  \"a\": 1\n}\n"
        try original.write(toFile: path, atomically: true, encoding: .utf8)

        let patch = """
        --- a/x.json
        +++ b/x.json
        @@ -1,3 +1,3 @@
         {
        -  "a": 1
        +  "a": ,
         }
        """
        let tool = PatchFileTool()
        let result = try await tool.execute(parameters: ["path": path, "patch": patch])
        #expect(result.isError)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == original)
    }
}
