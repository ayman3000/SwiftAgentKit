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
}