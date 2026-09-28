//
//  HarnessFixesTests.swift
//  Fixes from a reviewer watching an agent work a real repo (xontel,
//  2026-09-28): I-02 patch errors that misdirect, edit_file, I-03 relative
//  paths, I-04 search paths.
//

import Foundation
import Testing
@testable import SwiftAgentKitTools

private func tempDir(_ tag: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hf-\(tag)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return URL(fileURLWithPath: url.resolvingSymlinksInPath().path, isDirectory: true)
}

// MARK: I-02 — the error names the line that failed

@Test func aBulletWhoseDashWasEatenIsNamedInTheError() {
    let source = "# Notes\n- one\n- two\n- three\n"
    // Removing "- two" must be written "-- two"; written "- two", the dash is
    // read as the marker and the line becomes REMOVE " two".
    let patch = "@@ -1,4 +1,3 @@\n # Notes\n - one\n- two\n - three\n"
    guard case .failure(.hunkNotFound(_, _, _, let diagnosis)) = UnifiedDiff.apply(UnifiedDiff.parse(patch)!, to: source) else {
        Issue.record("expected hunkNotFound"); return
    }
    let d = diagnosis ?? ""
    #expect(d.contains("line 3"), "\(d)")
    #expect(d.contains("REMOVE"), "\(d)")
    #expect(d.contains("\"--"), "\(d)")          // says how to write it
    #expect(d.contains("line 3") && d.contains("- two"), "\(d)")   // what the file has there
}

@Test func theSameBulletWithItsMarkerApplies() {
    let source = "# Notes\n- one\n- two\n- three\n"
    let patch = "@@ -1,4 +1,3 @@\n # Notes\n - one\n-- two\n - three\n"
    guard case .success(let out) = UnifiedDiff.apply(UnifiedDiff.parse(patch)!, to: source) else {
        Issue.record("expected success"); return
    }
    #expect(out == "# Notes\n- one\n- three\n")
}

@Test func theErrorPointsPastTheLinesThatMatched() async throws {
    let dir = try tempDir("patch")
    let file = dir.appendingPathComponent("a.swift")
    try "let a = 1\nlet b = 2\nlet c = 3\nlet d = 4\n".write(to: file, atomically: true, encoding: .utf8)
    // The first three lines match; the fourth doesn't — the old preview showed only the first three.
    let patch = "@@ -1,4 +1,4 @@\n let a = 1\n let b = 2\n let c = 3\n-let d = 5\n+let d = 6\n"
    let r = try await PatchFileTool().execute(parameters: ["path": file.path, "patch": patch])
    #expect(r.isError)
    #expect(r.result.contains("line 4"), "\(r.result)")
    #expect(r.result.contains("let d = 5") && r.result.contains("let d = 4"), "\(r.result)")
}

// MARK: I-02 — edit_file

@Test func editFileReplacesAUniqueMatch() async throws {
    let dir = try tempDir("edit")
    let file = dir.appendingPathComponent("notes.md")
    try "# Roadmap\n- one\n- two\n".write(to: file, atomically: true, encoding: .utf8)
    let r = try await EditFileTool().execute(parameters: ["path": file.path, "old_text": "- two", "new_text": "- two (done)"])
    #expect(!r.isError, "\(r.result)")
    #expect(try String(contentsOf: file, encoding: .utf8) == "# Roadmap\n- one\n- two (done)\n")
}

@Test func editFileRefusesAMissingOrAmbiguousMatch() async throws {
    let dir = try tempDir("edit")
    let file = dir.appendingPathComponent("a.txt")
    try "x = 1\nx = 1\ny = 2\n".write(to: file, atomically: true, encoding: .utf8)
    let missing = try await EditFileTool().execute(parameters: ["path": file.path, "old_text": "z = 9", "new_text": "z = 0"])
    #expect(missing.isError && missing.result.contains("not found"), "\(missing.result)")
    let twice = try await EditFileTool().execute(parameters: ["path": file.path, "old_text": "x = 1", "new_text": "x = 2"])
    #expect(twice.isError && twice.result.contains("2 times"), "\(twice.result)")
    let all = try await EditFileTool().execute(parameters: ["path": file.path, "old_text": "x = 1", "new_text": "x = 2", "replace_all": true])
    #expect(!all.isError)
    #expect(try String(contentsOf: file, encoding: .utf8) == "x = 2\nx = 2\ny = 2\n")
}

@Test func editFileToleratesTrailingWhitespace() async throws {
    let dir = try tempDir("edit")
    let file = dir.appendingPathComponent("a.py")
    try "def f():   \n    return 1\n".write(to: file, atomically: true, encoding: .utf8)
    let r = try await EditFileTool().execute(parameters: ["path": file.path, "old_text": "def f():\n    return 1", "new_text": "def f():\n    return 2"])
    #expect(!r.isError, "\(r.result)")
    #expect(try String(contentsOf: file, encoding: .utf8).contains("return 2"))
}

// MARK: I-03 — relative paths resolve against the project

@Test func aRelativePathResolvesAgainstThePolicyBase() async throws {
    let root = try tempDir("proj")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("naseem"), withIntermediateDirectories: true)
    try "rules here".write(to: root.appendingPathComponent("naseem/rules.md"), atomically: true, encoding: .utf8)
    let policy = FileToolPolicy(allowedRoots: [root])
    let r = try await FileReadTool(policy: policy).execute(parameters: ["path": "naseem/rules.md"])
    #expect(!r.isError, "\(r.result)")
    #expect(r.result.contains("rules here"))
    // Escaping the root is still refused.
    let out = try await FileReadTool(policy: policy).execute(parameters: ["path": "../../etc/hosts"])
    #expect(out.isError)
}

// MARK: I-04 — search returns paths read_file opens unchanged

@Test func searchReturnsAbsolutePaths() async throws {
    let root = try tempDir("search")
    let sub = root.appendingPathComponent("src/app")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    try "print('hi')".write(to: sub.appendingPathComponent("runner.py"), atomically: true, encoding: .utf8)
    let r = try await SearchFilesTool().execute(parameters: ["directory": root.appendingPathComponent("src").path, "name": "runner"])
    let path = r.result.split(separator: "\n").first.map(String.init) ?? ""
    #expect(path.hasPrefix("/"), "\(r.result)")
    let read = try await FileReadTool().execute(parameters: ["path": path])
    #expect(!read.isError && read.result.contains("print('hi')"))
}
