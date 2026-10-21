import Foundation
import Testing
@testable import SwiftAgentKitTools

/// A host's private toolchain (Naseem's own Node in ~/.naseem/node) comes
/// first on PATH for every command.
struct ShellExtraPathTests {
    @Test func theCommandGetsTheDirectoriesFirst() {
        #expect(ShellTool.withPath("node -v", prepending: []) == "node -v")
        #expect(ShellTool.withPath("node -v", prepending: ["/a/bin", "/b c/bin"])
                == #"export PATH='/a/bin':'/b c/bin':"$PATH"; node -v"#)
        #expect(ShellTool.withPath("x", prepending: ["/it's"]).contains(#"'/it'\''s'"#))
    }

    @Test func aProgramInTheExtraDirectoryIsFound() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("extra-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("naseem-extra-path-probe")
        try "#!/bin/sh\necho found-it\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let path = dir.path
        let shell = ShellTool(extraPath: { [path] })
        let result = try await shell.execute(parameters: ["command": "naseem-extra-path-probe"])
        #expect(result.result.contains("found-it"), "\(result.result)")
    }
}
