#if os(macOS)
import Foundation
import SwiftAgentKit
import LLMProviderKit

// MARK: - MacAppsTool

/// Lists the running apps the model may drive now, and the running apps it may
/// still request. Access to an app outside the allowlist is granted on first use
/// by the host (automatically in autonomous mode, otherwise by asking the user).
public struct MacAppsTool: AgentTool {
    public let name = "mac_apps"
    public let description = """
    List the native macOS apps running on this Mac: the ones already allowed for this \
    conversation, and the ones you can still request. Pass `name` to look up an INSTALLED \
    app by name whether or not it is running (e.g. name: "Kommanda" → its bundle id, \
    path, and whether it is SCRIPTABLE) — this is how you get a bundle id you do not \
    know; never search the disk for it. Scriptable = it answers AppleScript, so a data \
    job can be one osascript call; not scriptable = drive it with the mac_* tools. Use \
    the bundle IDs here with the other mac_* tools. To use an app that is not yet \
    allowed, just call the mac_* tool you need (mac_launch, mac_ui, ...) with its bundle \
    id: access is granted automatically in autonomous mode, otherwise the user is asked \
    once.
    """
    public let parameters = ToolParameters(
        properties: [
            "name": ToolParameterProperty(
                type: "string",
                description: "Optional: an app name (or part of it) to look up among installed apps, running or not."),
        ],
        required: [])
    public var requiresConfirmation: Bool { false }

    let client: any AXDriving
    let allowlistProvider: @Sendable () -> Set<String>

    public init(client: any AXDriving, allowlistProvider: @escaping @Sendable () -> Set<String>) {
        self.client = client
        self.allowlistProvider = allowlistProvider
    }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        if let name = (parameters["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            let hits = AppResolver.installedApps(matching: name)
            guard !hits.isEmpty else {
                return .success(toolCallId: "", toolName: self.name,
                                result: "No installed app named like \"\(name)\" in the Applications folders. Check the spelling, or ask the user where it is.")
            }
            let lines = hits.prefix(6).map {
                "\($0.name) — \($0.bundleId) (\($0.path)) — "
                + (AppResolver.isScriptable(appAt: $0.path) ? "scriptable: AppleScript works for data jobs" : "not scriptable: use the mac_* tools")
            }
            return .success(toolCallId: "", toolName: self.name,
                            result: "Installed apps matching \"\(name)\":\n" + lines.joined(separator: "\n")
                            + "\nLaunch with mac_launch and the bundle id.")
        }
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
            "filter": ToolParameterProperty(
                type: "string",
                description: "Return only elements whose title, text or identifier contains this (case-insensitive), each with the window it is in. Cheap way to find one control in a big window."),
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
            if let filter = (parameters["filter"] as? String)?.trimmingCharacters(in: .whitespaces), !filter.isEmpty {
                return .success(toolCallId: "", toolName: name, result: tree.renderMatches(filter))
            }
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


// MARK: - MacScreenshotTool (opt-in)

/// Screenshot of a Mac app's front window. Registered only when the host opts in.
public struct MacScreenshotTool: AgentTool {
    public let name = "mac_screenshot"
    public let description = """
    Screenshot a native macOS app's front window as an image. The accessibility tree \
    from mac_ui is the normal way to see and act; use this only when mac_ui returns \
    nothing useful for the app, or when appearance and layout are the question (a \
    chart, a colour, overlapping views). Needs a vision-capable model and Screen \
    Recording permission. One screenshot per distinct screen — do not re-shoot.
    """
    public let parameters = ToolParameters(
        properties: [
            "bundle_id": ToolParameterProperty(
                type: "string",
                description: "Bundle id of the app whose front window to capture (see mac_apps)."),
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
        let bundleId: String
        switch AllowlistGuard.resolve(parameters, allowlist: allowlistProvider(), toolName: name) {
        case .failure(let e): return e
        case .success(let b): bundleId = b
        }
        do {
            let png = try await client.screenshot(bundleId: bundleId)
            return .success(toolCallId: "", toolName: name, result: "Screenshot of \(bundleId)'s front window captured.",
                            images: [LLMImage(data: png, mimeType: "image/png")])
        } catch let e as MacDriverError {
            return .error(toolCallId: "", toolName: name, message: e.localizedDescription)
        } catch {
            return .error(toolCallId: "", toolName: name, message: "mac_screenshot failed: \(error.localizedDescription)")
        }
    }
}

#endif
