#if os(macOS)
import Foundation
import SwiftAgentKit

// MARK: - MacClickTool

/// Clicks a UI element in a native macOS app.
public struct MacClickTool: AgentTool {
    public let name = "mac_click"
    public let description = """
    Click a UI element in a native macOS app identified by ref+generation, title, or \
    accessibility identifier. Use mac_ui first to get element refs. Refs from a previous \
    snapshot may be stale — check the generation number.
    """
    public let parameters = ToolParameters(
        properties: [
            "bundle_id": ToolParameterProperty(
                type: "string",
                description: "Bundle id of the target app (see mac_apps)."),
            "ref": ToolParameterProperty(
                type: "string",
                description: "Element ref from mac_ui (e.g. e3)."),
            "generation": ToolParameterProperty(
                type: "integer",
                description: "Tree generation the ref came from (guards against stale refs)."),
            "title": ToolParameterProperty(
                type: "string",
                description: "Fallback: match by element title."),
            "identifier": ToolParameterProperty(
                type: "string",
                description: "Fallback: match by accessibility identifier."),
        ],
        required: ["bundle_id"])
    public var requiresConfirmation: Bool { true }

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
        do {
            try await client.click(bundleId: bundleId, target: target)
            return .success(toolCallId: "", toolName: name, result: "Clicked.")
        } catch let e as MacDriverError {
            let treeText = e.tree.map { "\n\nCurrent UI:\n" + $0.renderCompact() } ?? ""
            return .error(toolCallId: "", toolName: name, message: e.localizedDescription + treeText)
        } catch {
            return .error(toolCallId: "", toolName: name, message: "mac_click failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - MacTypeTool

/// Types text into a focused or targeted UI element in a native macOS app.
public struct MacTypeTool: AgentTool {
    public let name = "mac_type"
    public let description = """
    Type text into the currently focused element (or into a targeted element) in a \
    native macOS app. Optionally supply ref+generation, title, or identifier to focus \
    the element first.
    """
    public let parameters = ToolParameters(
        properties: [
            "bundle_id": ToolParameterProperty(
                type: "string",
                description: "Bundle id of the target app (see mac_apps)."),
            "text": ToolParameterProperty(
                type: "string",
                description: "Text to type."),
            "ref": ToolParameterProperty(
                type: "string",
                description: "Optional element ref to focus before typing."),
            "generation": ToolParameterProperty(
                type: "integer",
                description: "Tree generation the ref came from."),
            "title": ToolParameterProperty(
                type: "string",
                description: "Fallback: focus element by title before typing."),
            "identifier": ToolParameterProperty(
                type: "string",
                description: "Fallback: focus element by accessibility identifier before typing."),
        ],
        required: ["bundle_id", "text"])
    public var requiresConfirmation: Bool { true }

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
        guard let text = parameters["text"] as? String else {
            return .error(toolCallId: "", toolName: name, message: "mac_type requires `text`.")
        }
        // Build optional target only if any target key is present
        let target: MacTarget? = {
            let t = MacTarget.from(parameters)
            return (t.ref != nil || t.title != nil || t.identifier != nil) ? t : nil
        }()
        do {
            try await client.type(bundleId: bundleId, text: text, target: target)
            return .success(toolCallId: "", toolName: name, result: "Typed.")
        } catch let e as MacDriverError {
            let treeText = e.tree.map { "\n\nCurrent UI:\n" + $0.renderCompact() } ?? ""
            return .error(toolCallId: "", toolName: name, message: e.localizedDescription + treeText)
        } catch {
            return .error(toolCallId: "", toolName: name, message: "mac_type failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - MacKeyTool

/// Sends a keyboard shortcut or key sequence to a native macOS app.
public struct MacKeyTool: AgentTool {
    public let name = "mac_key"
    public let description = """
    Send a keyboard shortcut or key sequence to a native macOS app. Use key names like \
    "return", "escape", "tab", or modifier combos like "cmd+s", "cmd+shift+z". \
    The app must be frontmost for key events to land correctly.
    """
    public let parameters = ToolParameters(
        properties: [
            "bundle_id": ToolParameterProperty(
                type: "string",
                description: "Bundle id of the target app (see mac_apps)."),
            "keys": ToolParameterProperty(
                type: "string",
                description: "Key or shortcut string, e.g. \"return\", \"cmd+s\", \"cmd+shift+z\"."),
        ],
        required: ["bundle_id", "keys"])
    public var requiresConfirmation: Bool { true }

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
        guard let keys = parameters["keys"] as? String else {
            return .error(toolCallId: "", toolName: name, message: "mac_key requires `keys`.")
        }
        do {
            try await client.key(bundleId: bundleId, keys: keys)
            return .success(toolCallId: "", toolName: name, result: "Key sent.")
        } catch let e as MacDriverError {
            let treeText = e.tree.map { "\n\nCurrent UI:\n" + $0.renderCompact() } ?? ""
            return .error(toolCallId: "", toolName: name, message: e.localizedDescription + treeText)
        } catch {
            return .error(toolCallId: "", toolName: name, message: "mac_key failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - MacLaunchTool

/// Launches an allowed native macOS app.
public struct MacLaunchTool: AgentTool {
    public let name = "mac_launch"
    public let description = """
    Launch a native macOS app by bundle ID. Only apps in the conversation allowlist can \
    be launched. After launching, use mac_ui to inspect the app's UI.
    """
    public let parameters = ToolParameters(
        properties: [
            "bundle_id": ToolParameterProperty(
                type: "string",
                description: "Bundle id of the app to launch (must be in the allowlist — see mac_apps)."),
        ],
        required: ["bundle_id"])
    public var requiresConfirmation: Bool { true }

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
            try await client.launch(bundleId: bundleId)
            return .success(toolCallId: "", toolName: name, result: "Launched \(bundleId).")
        } catch let e as MacDriverError {
            let treeText = e.tree.map { "\n\nCurrent UI:\n" + $0.renderCompact() } ?? ""
            return .error(toolCallId: "", toolName: name, message: e.localizedDescription + treeText)
        } catch {
            return .error(toolCallId: "", toolName: name, message: "mac_launch failed: \(error.localizedDescription)")
        }
    }
}

#endif
