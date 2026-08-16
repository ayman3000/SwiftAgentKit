//
//  SecurityFixesTests.swift
//  SwiftAgentKit
//
//  Tool-security fixes from the external review:
//  - ImportSkillTool: confirmation gate + SSRF blocking (private/loopback/link-local)
//  - FileToolPolicy: allowed-roots boundary with symlink/traversal canonicalization
//  - PythonTool: process-group kill on timeout (no orphan-holds-stdout hang)
//

import Foundation
import Testing
import SwiftAgentKit
@testable import SwiftAgentKitTools

// MARK: - ImportSkillTool SSRF hardening

@Test func importSkillRequiresConfirmation() {
    #expect(ImportSkillTool().requiresConfirmation == true)
}

@Test func importSkillBlocksPrivateAndLoopbackURLs() async throws {
    let tool = ImportSkillTool(fetch: { _ in (Data("should never be fetched".utf8), URLResponse()) })
    let blocked = [
        "http://127.0.0.1:8080/x",
        "http://localhost/skill.md",
        "http://10.0.0.5/x",
        "http://172.16.0.1/x",
        "http://192.168.1.10/x",
        "http://169.254.169.254/latest/meta-data/",
        "http://0.0.0.0/x",
        "http://[::1]/x",
        "http://[fe80::1]/x",
    ]
    for url in blocked {
        let r = try await tool.execute(parameters: ["url": url])
        #expect(r.isError == true, "expected \(url) to be blocked")
        #expect(!r.result.contains("should never be fetched"))
    }
}

@Test func importSkillStillAllowsPublicHostsWithInjectedFetch() async throws {
    let md = "# demo\nTriggers: demo\n\nstep 1\n"
    let tool = ImportSkillTool(fetch: { _ in (Data(md.utf8), URLResponse()) })
    let r = try await tool.execute(parameters: ["url": "https://example.com/skill.md"])
    #expect(r.isError == false)
    #expect(r.result.contains("name: demo"))
}

@Test func ssrfGuardClassifiesIPv4Ranges() {
    let blocked = ["127.0.0.1", "127.255.255.255", "10.1.2.3", "172.16.0.1", "172.31.255.255",
                   "192.168.0.1", "169.254.1.1", "100.64.0.1", "0.0.0.0"]
    for ip in blocked {
        #expect(SSRFGuard.blockReason(forHost: ip) != nil, "\(ip) should be blocked")
    }
    let allowed = ["93.184.216.34", "8.8.8.8", "172.32.0.1", "100.128.0.1"]
    for ip in allowed {
        #expect(SSRFGuard.blockReason(forHost: ip) == nil, "\(ip) should be allowed")
    }
}

@Test func ssrfGuardClassifiesIPv6Ranges() {
    let blocked = ["::1", "fe80::1", "fc00::1", "fd12:3456::1", "::ffff:127.0.0.1", "::ffff:192.168.1.1"]
    for ip in blocked {
        #expect(SSRFGuard.blockReason(forHost: ip) != nil, "\(ip) should be blocked")
    }
    #expect(SSRFGuard.blockReason(forHost: "2606:4700::1111") == nil)
}

@Test func ssrfGuardResolvesHostnamesAndBlocksPrivateResults() {
    // Injected resolver — no real DNS in tests.
    #expect(SSRFGuard.blockReason(forHost: "evil.example", resolve: { _ in ["127.0.0.1"] }) != nil)
    #expect(SSRFGuard.blockReason(forHost: "rebind.example", resolve: { _ in ["93.184.216.34", "192.168.1.1"] }) != nil)
    #expect(SSRFGuard.blockReason(forHost: "good.example", resolve: { _ in ["93.184.216.34"] }) == nil)
    #expect(SSRFGuard.blockReason(forHost: "unresolvable.example", resolve: { _ in [] }) != nil)
}

// MARK: - FileToolPolicy

private func makeTempDir(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sak-policy-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // Canonicalize (/tmp is a symlink to /private/tmp on macOS).
    return URL(fileURLWithPath: url.resolvingSymlinksInPath().path, isDirectory: true)
}

@Test func filePolicyAllowsReadsInsideRootAndBlocksOutside() async throws {
    let root = try makeTempDir("root")
    let outside = try makeTempDir("outside")
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }

    try "inside content".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try "confidential-payload".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)

    let tool = FileReadTool(policy: FileToolPolicy(allowedRoots: [root]))

    let ok = try await tool.execute(parameters: ["path": root.appendingPathComponent("a.txt").path])
    #expect(ok.isError == false)
    #expect(ok.result.contains("inside content"))

    let denied = try await tool.execute(parameters: ["path": outside.appendingPathComponent("secret.txt").path])
    #expect(denied.isError == true)
    #expect(denied.result.contains("outside"))
    #expect(!denied.result.contains("confidential-payload"))
}

@Test func filePolicyBlocksDotDotTraversal() async throws {
    let root = try makeTempDir("root")
    let outside = try makeTempDir("outside")
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    try "confidential-payload".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)

    let sneaky = root.path + "/../" + outside.lastPathComponent + "/secret.txt"
    let tool = FileReadTool(policy: FileToolPolicy(allowedRoots: [root]))
    let denied = try await tool.execute(parameters: ["path": sneaky])
    #expect(denied.isError == true)
    #expect(!denied.result.contains("confidential-payload"))
}

@Test func filePolicyBlocksSymlinkEscape() async throws {
    let root = try makeTempDir("root")
    let outside = try makeTempDir("outside")
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }

    try "confidential-payload".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
    let link = root.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(
        at: link, withDestinationURL: outside.appendingPathComponent("secret.txt"))

    let tool = FileReadTool(policy: FileToolPolicy(allowedRoots: [root]))
    let denied = try await tool.execute(parameters: ["path": link.path])
    #expect(denied.isError == true)
    #expect(!denied.result.contains("confidential-payload"))
}

@Test func filePolicyAppliesToWriteListAndSearch() async throws {
    let root = try makeTempDir("root")
    let outside = try makeTempDir("outside")
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }

    let policy = FileToolPolicy(allowedRoots: [root])

    // Write inside works, outside is blocked (and writes nothing).
    let write = FileWriteTool(policy: policy)
    let wIn = try await write.execute(parameters: ["path": root.appendingPathComponent("w.txt").path, "content": "hi"])
    #expect(wIn.isError == false)
    let outsideTarget = outside.appendingPathComponent("w.txt").path
    let wOut = try await write.execute(parameters: ["path": outsideTarget, "content": "hi"])
    #expect(wOut.isError == true)
    #expect(!FileManager.default.fileExists(atPath: outsideTarget))

    let list = ListDirTool(policy: policy)
    let lOut = try await list.execute(parameters: ["path": outside.path])
    #expect(lOut.isError == true)

    let search = SearchFilesTool(policy: policy)
    let sOut = try await search.execute(parameters: ["directory": outside.path, "name": "secret"])
    #expect(sOut.isError == true)

    let patch = PatchFileTool(policy: policy)
    let pOut = try await patch.execute(parameters: [
        "path": outside.appendingPathComponent("x.txt").path,
        "patch": "@@ -1 +1 @@\n-a\n+b\n",
    ])
    #expect(pOut.isError == true)
}

@Test func fileToolsWithoutPolicyRemainUnrestricted() async throws {
    let dir = try makeTempDir("free")
    defer { try? FileManager.default.removeItem(at: dir) }
    try "free content".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

    let r = try await FileReadTool().execute(parameters: ["path": dir.appendingPathComponent("f.txt").path])
    #expect(r.isError == false)
    #expect(r.result.contains("free content"))
}

// MARK: - PythonTool process-group timeout

#if os(macOS)
@Test func pythonTimesOutEvenWhenOrphanHoldsStdout() async throws {
    let venv = FileManager.default.temporaryDirectory
        .appendingPathComponent("sak-python-venv-test", isDirectory: true)
    let tool = PythonTool(venvPath: venv, timeoutSeconds: 2)

    let start = Date()
    // The child `sleep 30` inherits stdout; killing only the python process
    // would leave the pipe open and block the read for the full 30s.
    let r = try await tool.execute(parameters: [
        "code": "import subprocess, time\nsubprocess.Popen(['sleep', '30'])\ntime.sleep(30)\n"
    ])
    let elapsed = Date().timeIntervalSince(start)

    #expect(elapsed < 20, "run took \(elapsed)s — orphan held the pipe past the timeout")
    #expect(r.result.contains("timeout"))
}
#endif
