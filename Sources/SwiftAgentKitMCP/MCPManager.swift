import Foundation
import SwiftAgentKit
import MCP

/// Manages MCP server connections and bridges discovered tools into `AgentTool`s.
///
/// Usage:
/// ```swift
/// let mcp = MCPManager()
/// try await mcp.connect(.stdio(command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]))
/// let tools = try await mcp.bridgedTools()
/// for tool in tools { agent.register(tool) }
/// ```
public actor MCPManager {

    private var connections: [MCPConnection] = []

    public init() {}

    /// Connect to an MCP server using the given configuration.
    @discardableResult
    public func connect(_ config: MCPClientConfig) async throws -> MCPServerInfo {
        let client = Client(name: "SwiftAgentKit", version: "0.3.0-alpha.5")

        let transport: Transport
        var process: Process?

        switch config {
        case .stdio(let command, let args, let env):
            // GUI-launched macOS apps have a minimal PATH. Resolve command names
            // against PATH plus common package-manager locations before spawning.
            let processEnvironment = ProcessInfo.processInfo.environment.merging(env ?? [:]) { _, custom in custom }
            let executableURL = try MCPExecutableResolver.resolve(
                command,
                environment: processEnvironment
            )

            // Spawn the MCP server as a subprocess and pipe its stdio
            let proc = Process()
            proc.executableURL = executableURL
            proc.arguments = args
            proc.environment = processEnvironment

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            proc.standardInput = stdinPipe
            proc.standardOutput = stdoutPipe
            proc.standardError = Pipe()  // swallow stderr

            try proc.run()

            // StdioTransport takes FileDescriptor — get the write end of stdin
            // and the read end of stdout
            let writeFD = stdinPipe.fileHandleForWriting.fileDescriptor
            let readFD = stdoutPipe.fileHandleForReading.fileDescriptor

            transport = StdioTransport(
                input: .init(rawValue: readFD),
                output: .init(rawValue: writeFD)
            )
            process = proc

        case .http(let endpoint):
            transport = HTTPClientTransport(endpoint: endpoint)
        }

        let result = try await client.connect(transport: transport)
        let info = MCPServerInfo(
            name: result.serverInfo.name,
            version: result.serverInfo.version
        )

        connections.append(MCPConnection(
            client: client,
            transport: transport,
            serverName: result.serverInfo.name,
            config: config,
            process: process
        ))

        return info
    }

    /// Disconnect from a specific MCP server by name.
    public func disconnect(serverName: String) async {
        let toRemove = connections.filter { $0.serverName == serverName }
        for conn in toRemove {
            await conn.client.disconnect()
            conn.process?.terminate()
        }
        connections.removeAll { $0.serverName == serverName }
    }

    /// Disconnect from all MCP servers.
    public func disconnectAll() async {
        for conn in connections {
            await conn.client.disconnect()
            conn.process?.terminate()
        }
        connections.removeAll()
    }

    /// List all discovered tools from all connected MCP servers, bridged as `AgentTool`s.
    public func bridgedTools() async throws -> [any AgentTool] {
        var tools: [any AgentTool] = []
        for conn in connections {
            let (mcpTools, _) = try await conn.client.listTools()
            for tool in mcpTools {
                tools.append(MCPToolBridge(tool: tool, client: conn.client, serverName: conn.serverName))
            }
        }
        return tools
    }

    /// List tool names from all connected servers.
    public func toolNames() async throws -> [String] {
        let tools = try await bridgedTools()
        return tools.map { $0.name }
    }

    /// List connected server names.
    public func connectedServers() -> [String] {
        connections.map { $0.serverName }
    }

    /// List all resources from all connected MCP servers.
    public func listResources() async throws -> [MCPResourceInfo] {
        var resources: [MCPResourceInfo] = []
        for conn in connections {
            let (mcpResources, _) = try await conn.client.listResources()
            for res in mcpResources {
                resources.append(MCPResourceInfo(
                    uri: res.uri,
                    name: res.name,
                    description: res.description,
                    serverName: conn.serverName
                ))
            }
        }
        return resources
    }

    /// Read a resource from the MCP server that provides it.
    public func readResource(uri: String) async throws -> String {
        for conn in connections {
            let contents = try await conn.client.readResource(uri: uri)
            var text = ""
            for content in contents {
                if let t = content.text { text += t }
            }
            if !text.isEmpty { return text }
        }
        throw MCPManagerError.resourceNotFound(uri)
    }

    /// Build a context block from all MCP resources, suitable for injection into a system prompt.
    public func resourcesContextBlock() async throws -> String {
        let resources = try await listResources()
        if resources.isEmpty { return "" }

        var lines = ["## MCP Resources"]
        for res in resources {
            let desc = res.description.map { " — \($0)" } ?? ""
            lines.append("- \(res.name) (`\(res.uri)`)\(desc)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - MCP Resource Info

/// Metadata about a discovered MCP resource.
public struct MCPResourceInfo: Sendable {
    public let uri: String
    public let name: String
    public let description: String?
    public let serverName: String

    public init(uri: String, name: String, description: String?, serverName: String) {
        self.uri = uri
        self.name = name
        self.description = description
        self.serverName = serverName
    }
}

// MARK: - Errors

public enum MCPManagerError: Error, LocalizedError {
    case executableNotFound(String)
    case resourceNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let command):
            return "MCP executable not found: \(command). Install it or provide an absolute path."
        case .resourceNotFound(let uri):
            return "MCP resource not found: \(uri)"
        }
    }
}

// MARK: - Internal

private struct MCPConnection {
    let client: Client
    let transport: Transport
    let serverName: String
    let config: MCPClientConfig
    let process: Process?
}