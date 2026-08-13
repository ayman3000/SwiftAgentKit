#if os(macOS)
import Foundation
import SwiftAgentKit

// MARK: - MacAppsTool

/// Lists all allowlisted apps that are currently running on this Mac.
public struct MacAppsTool: AgentTool {
    public let name = "mac_apps"
    public let description = """
    List the native macOS apps that are currently running AND permitted for this \
    conversation. Use the bundle IDs here with the other mac_* tools. If the app you \
    need is not listed, ask the user to allow it or launch it with mac_launch.
    """
    public let parameters = ToolParameters.empty
    public var requiresConfirmation: Bool { false }

    let client: any AXDriving
    let allowlistProvider: @Sendable () -> Set<String>

    public init(client: any AXDriving, allowlistProvider: @escaping @Sendable () -> Set<String>) {
        self.client = client
        self.allowlistProvider = allowlistProvider
    }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let allowed = AppResolver.filterAllowed(client.runningApps(), allowlist: allowlistProvider())
        if allowed.isEmpty {
            return .success(
                toolCallId: "",
                toolName: name,
                result: "No allowed apps are running. Ask the user to allow an app, or launch one with mac_launch.")
        }
        let lines = allowed.map { "\($0.name) — \($0.bundleId)" }.joined(separator: "\n")
        return .success(toolCallId: "", toolName: name, result: lines)
    }
}

// MARK: - MacUITool

/// Reads the live accessibility tree of a native macOS app.
public struct MacUITool: AgentTool {
    public let name = "mac_ui"
    public let description = """
    Read the accessibility tree of a native macOS app (element refs, roles, titles, \
    values, available actions). Use this to see and navigate GUI-only apps that have \
    no CLI/API. Prefer this over guessing coordinates. Refs are valid only until the \
    next snapshot (each tree shows its generation). Only apps allowed for this \
    conversation are accessible.
    """
    public let parameters = ToolParameters(
        properties: [
            "bundle_id": ToolParameterProperty(
                type: "string",
                description: "Bundle id of the app to inspect (see mac_apps).")
        ],
        required: ["bundle_id"])
    public var requiresConfirmation: Bool { false }

    let client: any AXDriving
    let allowlistProvider: @Sendable () -> Set<String>

    public init(client: any AXDriving, allowlistProvider: @escaping @Sendable () -> Set<String>) {
        self.client = client
        self.allowlistProvider = allowlistProvider
    }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        if let err = accessibilityError(toolName: name, client: client) { return err }
        let bundleId: String
        switch AllowlistGuard.resolve(parameters, allowlist: allowlistProvider(), toolName: name) {
        case .failure(let e): return e
        case .success(let b): bundleId = b
        }
        do {
            let tree = try await client.snapshot(bundleId: bundleId)
            return .success(toolCallId: "", toolName: name, result: tree.renderCompact())
        } catch let e as MacDriverError {
            let treeText = e.tree.map { "\n\nCurrent UI:\n" + $0.renderCompact() } ?? ""
            return .error(toolCallId: "", toolName: name, message: e.localizedDescription + treeText)
        } catch {
            return .error(toolCallId: "", toolName: name, message: "mac_ui failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - MacWaitTool

/// Waits for a UI element to appear (or disappear) in a native macOS app.
public struct MacWaitTool: AgentTool {
    public let name = "mac_wait"
    public let description = """
    Wait for a UI element to appear (or disappear) in a native macOS app. Returns the \
    updated UI tree when the condition is met, or an error with the current tree on timeout. \
    Use after triggering an action that causes the UI to change.
    """
    public let parameters = ToolParameters(
        properties: [
            "bundle_id": ToolParameterProperty(
                type: "string",
                description: "Bundle id of the app to watch (see mac_apps)."),
            "title": ToolParameterProperty(
                type: "string",
                description: "Element title to wait for."),
            "identifier": ToolParameterProperty(
                type: "string",
                description: "Element accessibility identifier to wait for."),
            "timeout_seconds": ToolParameterProperty(
                type: "number",
                description: "Maximum seconds to wait (default 10)."),
            "for_disappearance": ToolParameterProperty(
                type: "boolean",
                description: "If true, wait for the element to disappear instead of appear."),
        ],
        required: ["bundle_id"])
    public var requiresConfirmation: Bool { false }

    let client: any AXDriving
    let allowlistProvider: @Sendable () -> Set<String>

    public init(client: any AXDriving, allowlistProvider: @escaping @Sendable () -> Set<String>) {
        self.client = client
        self.allowlistProvider = allowlistProvider
    }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        if let err = accessibilityError(toolName: name, client: client) { return err }
        let bundleId: String
        switch AllowlistGuard.resolve(parameters, allowlist: allowlistProvider(), toolName: name) {
        case .failure(let e): return e
        case .success(let b): bundleId = b
        }
        let target = MacTarget.from(parameters)
        let timeout = parameters["timeout_seconds"] as? Double ?? 10.0
        let forDisappearance = parameters["for_disappearance"] as? Bool ?? false
        do {
            let tree = try await client.waitFor(
                bundleId: bundleId,
                target: target,
                timeoutSeconds: timeout,
                forDisappearance: forDisappearance)
            return .success(toolCallId: "", toolName: name, result: tree.renderCompact())
        } catch let e as MacDriverError {
            let treeText = e.tree.map { "\n\nCurrent UI:\n" + $0.renderCompact() } ?? ""
            return .error(toolCallId: "", toolName: name, message: e.localizedDescription + treeText)
        } catch {
            return .error(toolCallId: "", toolName: name, message: "mac_wait failed: \(error.localizedDescription)")
        }
    }
}

#endif
