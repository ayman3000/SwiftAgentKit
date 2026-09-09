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
    snapshot may be stale — check the generation number. Buttons are pressed, rows and \
    list items are selected; to OPEN a row (a folder, a file, a mail) use clicks:2. The \
    element is scrolled into view when the app allows it. `title` also matches an \
    element's visible text, case-insensitively, then as a substring.
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
            "clicks": ToolParameterProperty(
                type: "integer",
                description: "1 (default) or 2 for a double-click (opens rows, files, folders)."),
            "button": ToolParameterProperty(
                type: "string",
                description: "\"left\" (default) or \"right\" for a context menu."),
            "item": ToolParameterProperty(
                type: "string",
                description: "For a pop-up or menu button: open it and choose the item with this title in one go (e.g. the File Format pop-up in a Save sheet → \"Plain Text\"). Fails listing the items it saw."),
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
        guard target.ref != nil || target.title != nil || target.identifier != nil else {
            return .error(toolCallId: "", toolName: name,
                          message: "mac_click needs a ref (from mac_ui), title, or identifier to click.")
        }
        let clicks = (parameters["clicks"] as? Int) ?? Int((parameters["clicks"] as? Double) ?? 1)
        let right = ((parameters["button"] as? String) ?? "left").lowercased() == "right"
        do {
            if let item = parameters["item"] as? String, !item.isEmpty {
                let how = try await client.choose(bundleId: bundleId, target: target, item: item)
                return .success(toolCallId: "", toolName: name, result: how)
            }
            let how = try await client.click(bundleId: bundleId, target: target,
                                             options: MacClickOptions(clicks: clicks, rightButton: right))
            return .success(toolCallId: "", toolName: name, result: how)
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
            "replace": ToolParameterProperty(
                type: "boolean",
                description: "Select the field's existing content first so the text replaces it (default false = append at the cursor)."),
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
            let replace = (parameters["replace"] as? Bool) ?? false
            let verified = try await client.type(bundleId: bundleId, text: text, target: target, replace: replace)
            return .success(toolCallId: "", toolName: name, result: verified
                ? "Typed; the focused field now contains the text. No need to re-check or retype."
                : "Typed; sent to the focused field, whose content cannot be read back. Confirm with mac_ui only if it matters.")
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
    Send a keyboard shortcut or a sequence of them to a native macOS app. Key names: \
    return, escape, tab, space, backspace, up/down/left/right, home, end, pageup, \
    pagedown, f1-f12, letters and digits; modifiers cmd, shift, opt, ctrl. A sequence is \
    comma-separated: "cmd+a, cmd+c". The app is brought to the front first.
    """
    public let parameters = ToolParameters(
        properties: [
            "bundle_id": ToolParameterProperty(
                type: "string",
                description: "Bundle id of the target app (see mac_apps)."),
            "keys": ToolParameterProperty(
                type: "string",
                description: "Key or shortcut string, e.g. \"return\", \"backspace\", \"escape\", \"tab\", \"up\", \"cmd+s\", \"cmd+shift+z\"."),
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
    Launch a native macOS app by bundle ID, or bring it to the front if it is already \
    running. An app not yet allowed for this conversation is requested on first use \
    (automatic in autonomous mode, otherwise the user is asked once). After launching, \
    use mac_ui to inspect the app's UI. Do not use the shell or AppleScript to open or \
    drive a GUI app instead.
    """
    public let parameters = ToolParameters(
        properties: [
            "bundle_id": ToolParameterProperty(
                type: "string",
                description: "Bundle id of the app to launch (see mac_apps; an app not yet allowed is requested on first use)."),
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


// MARK: - MacScrollTool

/// Scrolls a view in a native macOS app.
public struct MacScrollTool: AgentTool {
    public let name = "mac_scroll"
    public let description = """
    Scroll in a native macOS app: the front window, or the element named by \
    ref+generation / title / identifier (a list, a table, a web view). Use it when the \
    thing you need is below the visible rows or mac_click reports the element is off \
    screen. Then read again with mac_ui.
    """
    public let parameters = ToolParameters(
        properties: [
            "bundle_id": ToolParameterProperty(
                type: "string",
                description: "Bundle id of the target app (see mac_apps)."),
            "direction": ToolParameterProperty(
                type: "string",
                description: "up, down, left or right."),
            "amount": ToolParameterProperty(
                type: "integer",
                description: "How many lines to scroll (default 10, max 100)."),
            "ref": ToolParameterProperty(type: "string", description: "Optional element ref to scroll within."),
            "generation": ToolParameterProperty(type: "integer", description: "Tree generation the ref came from."),
            "title": ToolParameterProperty(type: "string", description: "Optional: element title/text to scroll within."),
            "identifier": ToolParameterProperty(type: "string", description: "Optional: accessibility identifier to scroll within."),
        ],
        required: ["bundle_id", "direction"])
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
        guard let direction = parameters["direction"] as? String else {
            return .error(toolCallId: "", toolName: name, message: "mac_scroll requires `direction`.")
        }
        let amount = (parameters["amount"] as? Int) ?? Int((parameters["amount"] as? Double) ?? 10)
        let t = MacTarget.from(parameters)
        let target: MacTarget? = (t.ref != nil || t.title != nil || t.identifier != nil) ? t : nil
        do {
            try await client.scroll(bundleId: bundleId, target: target, direction: direction, amount: amount)
            return .success(toolCallId: "", toolName: name, result: "Scrolled \(direction.lowercased()) \(amount) lines. Read again with mac_ui to see what is visible now.")
        } catch let e as MacDriverError {
            return .error(toolCallId: "", toolName: name, message: e.localizedDescription)
        } catch {
            return .error(toolCallId: "", toolName: name, message: "mac_scroll failed: \(error.localizedDescription)")
        }
    }
}

#endif
