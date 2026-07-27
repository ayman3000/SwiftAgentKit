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

    /// Timeout (seconds) for the initial connect/handshake with an MCP server.
    public var connectTimeout: TimeInterval = 30

    /// Timeout (seconds) for individual MCP requests (listTools, listResources,
    /// readResource). Tool-call timeouts are configured on `MCPToolBridge`.
    public var requestTimeout: TimeInterval = 60

    public init() {}

    /// Connect to an MCP server using the given configuration.
    @discardableResult
    public func connect(_ config: MCPClientConfig) async throws -> MCPServerInfo {
        let client = Client(name: "SwiftAgentKit", version: "0.3.0-alpha.7")

        let transport: Transport
        var process: Process?

        switch config {
        case .stdio(let command, let args, let env):
            // GUI-launched macOS apps have a minimal PATH. Resolve command names
            // against PATH plus common package-manager locations before spawning.
            let customEnvironment = ProcessInfo.processInfo.environment.merging(env ?? [:]) { _, custom in custom }
            let processEnvironment = MCPExecutableResolver.enrichedEnvironment(customEnvironment)
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
            // Discard stderr via /dev/null. A plain unread `Pipe()` would fill its
            // ~64KB OS buffer on a chatty server and block the server's writes.
            proc.standardError = FileHandle.nullDevice

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

        // Bound the handshake and clean up the spawned process if it fails or
        // times out — otherwise a server that never completes initialization
        // would hang the caller forever and leak the child process.
        do {
            let result = try await withMCPTimeout(connectTimeout) {
                try await client.connect(transport: transport)
            }
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
        } catch {
            process?.terminate()
            throw error
        }
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
            let (mcpTools, _) = try await withMCPTimeout(requestTimeout) {
                try await conn.client.listTools()
            }
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
            let (mcpResources, _) = try await withMCPTimeout(requestTimeout) {
                try await conn.client.listResources()
            }
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
    ///
    /// Servers that don't own the URI typically throw; we swallow per-server
    /// errors and try the next connection so one server's "unknown resource"
    /// doesn't mask a resource owned by another.
    public func readResource(uri: String) async throws -> String {
        for conn in connections {
            do {
                let contents = try await withMCPTimeout(requestTimeout) {
                    try await conn.client.readResource(uri: uri)
                }
                var text = ""
                for content in contents {
                    if let t = content.text { text += t }
                }
                if !text.isEmpty { return text }
            } catch {
                continue
            }
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
    case timedOut(TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let command):
            return "MCP executable not found: \(command). Install it or provide an absolute path."
        case .resourceNotFound(let uri):
            return "MCP resource not found: \(uri)"
        case .timedOut(let seconds):
            return "MCP request timed out after \(Int(seconds))s."
        }
    }
}

// MARK: - Timeout helper

/// Run an async MCP operation with a wall-clock timeout. If it doesn't finish
/// in `seconds`, the operation task is cancelled and `MCPManagerError.timedOut`
/// is thrown. The MCP SDK exposes no per-request timeout, and a stdio server
/// that hangs (or never answers a request) would otherwise block forever.
func withMCPTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw MCPManagerError.timedOut(seconds)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw MCPManagerError.timedOut(seconds)
        }
        return result
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