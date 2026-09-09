#if os(macOS)
import Foundation
import SwiftAgentKit

// MARK: - MacAppsTool

/// Lists the running apps the model may drive now, and the running apps it may
/// still request. Access to an app outside the allowlist is granted on first use
/// by the host (automatically in autonomous mode, otherwise by asking the user).
public struct MacAppsTool: AgentTool {
    public let name = "mac_apps"
    public let description = """
    List the native macOS apps running on this Mac: the ones already allowed for this \
    conversation, and the ones you can still request. Use the bundle IDs here with the \
    other mac_* tools. To use an app that is not yet allowed, just call the mac_* tool \
    you need (mac_launch, mac_ui, ...) with its bundle id: access is granted \
    automatically in autonomous mode, otherwise the user is asked once. Never drive a \
    GUI app through the shell or AppleScript instead of these tools.
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
        let running = client.runningApps()
        let allowlist = allowlistProvider()
        let allowed = AppResolver.filterAllowed(running, allowlist: allowlist)
        let requestable = running.filter { !allowlist.contains($0.bundleId) }
        var out: [String] = []
        if allowed.isEmpty {
            out.append("No allowed apps are running yet.")
        } else {
            out.append("Allowed and running:")
            out += allowed.map { "  \($0.name) — \($0.bundleId)" }
        }
        if !requestable.isEmpty {
            out.append("Running, not yet allowed (call any mac_* tool with the bundle id to request access; "
                       + "granted automatically in autonomous mode, otherwise the user is asked once):")
            out += requestable.map { "  \($0.name) — \($0.bundleId)" }
        }
        out.append("An app that is not running can be started with mac_launch and its bundle id; "
                   + "access is requested the same way.")
        return .success(toolCallId: "", toolName: name, result: out.joined(separator: "\n"))
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
    next snapshot (each tree shows its generation). This is how you see a Mac app: \
    there is no Mac screenshot tool, and sim_* tools only see the iOS Simulator. An app \
    not yet allowed for this conversation is requested on first use (automatic in \
    autonomous mode, otherwise the user is asked once).
    """
    public let parameters = ToolParameters(
        properties: [
            "bundle_id": ToolParameterProperty(
                type: "string",
                description: "Bundle id of the app to inspect (see mac_apps)."),
            "include_menus": ToolParameterProperty(
                type: "boolean",
                description: "Also list every menu item of the menu bar (default false; menus are collapsed to their titles)."),
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
            let includeMenus = parameters["include_menus"] as? Bool ?? false
            return .success(toolCallId: "", toolName: name, result: tree.renderCompact(includeMenus: includeMenus))
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
