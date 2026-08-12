#if os(macOS)
import Foundation
import SwiftAgentKit

// MARK: - SimListTool

/// Lists available iOS simulators (no confirmation needed — read-only).
public struct SimListTool: AgentTool {
    public let name = "sim_list"
    public let description = """
    List all available iOS simulators with their UDID, name, runtime, and boot state. \
    Use this to find a device to boot before launching an app.
    """
    public let parameters = ToolParameters(properties: [:], required: [])
    public init() {}

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        do {
            let devices = try await Simctl.listDevices()
            if devices.isEmpty {
                return .success(toolCallId: "", toolName: name, result: "No simulators available.")
            }
            let lines = devices.map { d in
                "\(d.isBooted ? "● " : "○ ")\(d.name) [\(d.udid)] \(d.runtime)\(d.isBooted ? " (Booted)" : "")"
            }
            return .success(toolCallId: "", toolName: name, result: lines.joined(separator: "\n"))
        } catch {
            return .error(toolCallId: "", toolName: name, message: "simctl list failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - SimBootTool

/// Boots a simulator by UDID or name. Requires confirmation.
public struct SimBootTool: AgentTool {
    public let name = "sim_boot"
    public let description = """
    Boot an iOS simulator. Provide either `udid` (exact match) or `name` \
    (first matching device). Sets the active device for subsequent sim_* calls. \
    Boots the Simulator.app automatically.
    """
    public let parameters = ToolParameters(
        properties: [
            "udid": ToolParameterProperty(type: "string", description: "Exact UDID of the simulator to boot."),
            "name": ToolParameterProperty(type: "string", description: "Device name to match (first match), e.g. 'iPhone 15 Pro'."),
        ],
        required: [])
    public var requiresConfirmation: Bool { true }
    let session: SimSession
    public init(session: SimSession) { self.session = session }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        do {
            let devices = try await Simctl.listDevices()
            let device: Simctl.SimDevice?
            if let udid = parameters["udid"] as? String, !udid.isEmpty {
                device = devices.first { $0.udid == udid }
            } else if let name = parameters["name"] as? String, !name.isEmpty {
                device = devices.first { $0.name.localizedCaseInsensitiveContains(name) }
            } else {
                return .error(toolCallId: "", toolName: name,
                    message: "sim_boot requires either `udid` or `name`.")
            }
            guard let dev = device else {
                return .error(toolCallId: "", toolName: name,
                    message: "No simulator found matching the given udid/name. Run sim_list to see available devices.")
            }
            if !dev.isBooted {
                try await Simctl.boot(udid: dev.udid)
            }
            session.udid = dev.udid
            session.runtime = dev.runtime
            return .success(toolCallId: "", toolName: name,
                result: "Booted \(dev.name) [\(dev.udid)] (\(dev.runtime)).")
        } catch {
            return .error(toolCallId: "", toolName: name, message: "sim_boot failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - SimLaunchTool

/// Launches an app bundle in the booted simulator. Requires confirmation.
public struct SimLaunchTool: AgentTool {
    public let name = "sim_launch"
    public let description = """
    Launch an app by bundle ID in the currently booted simulator. \
    Sets the app as the active target for sim_ui, sim_tap, etc. \
    Pass `terminate_first: true` to force a fresh launch.
    """
    public let parameters = ToolParameters(
        properties: [
            "bundle_id": ToolParameterProperty(type: "string", description: "App bundle ID to launch, e.g. com.example.MyApp."),
            "terminate_first": ToolParameterProperty(type: "boolean", description: "Terminate before launching (force fresh start)."),
        ],
        required: ["bundle_id"])
    public var requiresConfirmation: Bool { true }
    let client: any SimDriving
    let session: SimSession
    public init(client: any SimDriving, session: SimSession) { self.client = client; self.session = session }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let bundleId = parameters["bundle_id"] as? String, !bundleId.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "sim_launch requires `bundle_id`.")
        }
        let terminateFirst = (parameters["terminate_first"] as? Bool) ?? false
        do {
            try await client.launch(bundleId: bundleId, terminateFirst: terminateFirst)
            session.currentBundleId = bundleId
            return .success(toolCallId: "", toolName: name,
                result: "Launched \(bundleId). Use sim_ui to inspect the initial screen.")
        } catch let e as SimDriverError {
            return .error(toolCallId: "", toolName: name,
                message: e.localizedDescription + (e.tree.map { "\n\nCurrent UI:\n" + $0.renderCompact() } ?? ""))
        } catch {
            return .error(toolCallId: "", toolName: name, message: "sim_launch failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - SimTerminateTool

/// Terminates a running app in the simulator. Requires confirmation.
public struct SimTerminateTool: AgentTool {
    public let name = "sim_terminate"
    public let description = """
    Terminate a running app in the simulator. \
    Clears the active bundle ID if it matches the terminated app.
    """
    public let parameters = ToolParameters(
        properties: [
            "bundle_id": ToolParameterProperty(type: "string",
                description: "Bundle ID to terminate; defaults to the current app under test."),
        ],
        required: [])
    public var requiresConfirmation: Bool { true }
    let client: any SimDriving
    let session: SimSession
    public init(client: any SimDriving, session: SimSession) { self.client = client; self.session = session }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let bundleId: String
        switch resolveBundleId(parameters, session, toolName: name) {
        case .missing(let e): return e
        case .resolved(let b): bundleId = b
        }
        do {
            try await client.terminate(bundleId: bundleId)
            if session.currentBundleId == bundleId {
                session.currentBundleId = nil
            }
            return .success(toolCallId: "", toolName: name, result: "Terminated \(bundleId).")
        } catch let e as SimDriverError {
            return .error(toolCallId: "", toolName: name,
                message: e.localizedDescription + (e.tree.map { "\n\nCurrent UI:\n" + $0.renderCompact() } ?? ""))
        } catch {
            return .error(toolCallId: "", toolName: name, message: "sim_terminate failed: \(error.localizedDescription)")
        }
    }
}
#endif
