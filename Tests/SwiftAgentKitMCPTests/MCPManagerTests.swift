import XCTest
import SwiftAgentKit
@testable import SwiftAgentKitMCP

final class MCPManagerTests: XCTestCase {

    func testManagerCreatesWithNoConnections() async {
        let manager = MCPManager()
        let servers = await manager.connectedServers()
        XCTAssertTrue(servers.isEmpty)
    }

    func testConfigStdioEquality() {
        let config = MCPClientConfig.stdio(command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"])
        switch config {
        case .stdio(let command, let args, _):
            XCTAssertEqual(command, "npx")
            XCTAssertEqual(args, ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"])
        case .http:
            XCTFail("Expected stdio config")
        }
    }

    func testConfigHTTP() {
        let url = URL(string: "http://localhost:8080")!
        let config = MCPClientConfig.http(endpoint: url)
        switch config {
        case .http(let endpoint):
            XCTAssertEqual(endpoint, url)
        case .stdio:
            XCTFail("Expected http config")
        }
    }

    func testMCPServerInfo() {
        let info = MCPServerInfo(name: "test-server", version: "1.0.0")
        XCTAssertEqual(info.name, "test-server")
        XCTAssertEqual(info.version, "1.0.0")
    }

    func testMCPResourceInfo() {
        let res = MCPResourceInfo(
            uri: "file:///tmp/test.txt",
            name: "Test File",
            description: "A test resource",
            serverName: "fs-server"
        )
        XCTAssertEqual(res.uri, "file:///tmp/test.txt")
        XCTAssertEqual(res.name, "Test File")
        XCTAssertEqual(res.description, "A test resource")
        XCTAssertEqual(res.serverName, "fs-server")
    }

    func testMCPManagerErrorDescription() {
        let error = MCPManagerError.resourceNotFound("file:///missing")
        XCTAssertEqual(error.localizedDescription, "MCP resource not found: file:///missing")
    }

    func testListResourcesEmpty() async {
        let manager = MCPManager()
        let resources = try? await manager.listResources()
        XCTAssertTrue(resources?.isEmpty ?? false)
    }

    func testResourcesContextBlockEmpty() async throws {
        let manager = MCPManager()
        let block = try await manager.resourcesContextBlock()
        XCTAssertEqual(block, "")
    }

    func testExecutableResolverFindsCommandOnPATH() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("test-mcp")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let resolved = try MCPExecutableResolver.resolve(
            "test-mcp",
            environment: ["PATH": directory.path]
        )
        XCTAssertEqual(resolved.standardizedFileURL, executable.standardizedFileURL)
    }

    func testExecutableResolverFindsUserLocalBinForGUIEnvironment() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-home-\(UUID().uuidString)", isDirectory: true)
        let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let executable = bin.appendingPathComponent("npx")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let resolved = try MCPExecutableResolver.resolve(
            "npx",
            environment: ["PATH": "/usr/bin:/bin"],
            homeDirectory: home
        )
        XCTAssertEqual(resolved.standardizedFileURL, executable.standardizedFileURL)
    }

    func testExecutableResolverReportsMissingCommand() {
        XCTAssertThrowsError(
            try MCPExecutableResolver.resolve(
                "definitely-not-an-mcp-command",
                environment: ["PATH": ""],
                homeDirectory: URL(fileURLWithPath: "/nonexistent")
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "MCP executable not found: definitely-not-an-mcp-command. Install it or provide an absolute path."
            )
        }
    }
}