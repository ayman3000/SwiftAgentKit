#if os(macOS)
import Foundation
import SwiftAgentKit
import LLMProviderKit

// MARK: - SimSession

/// Mutable session state shared by the sim_* tool set (current app under test, device).
public final class SimSession: @unchecked Sendable {
    private let lock = NSLock()
    private var _currentBundleId: String?
    private var _udid: String?
    private var _runtime: String?

    public var currentBundleId: String? {
        get { lock.lock(); defer { lock.unlock() }; return _currentBundleId }
        set { lock.lock(); defer { lock.unlock() }; _currentBundleId = newValue }
    }
    public var udid: String? {
        get { lock.lock(); defer { lock.unlock() }; return _udid }
        set { lock.lock(); defer { lock.unlock() }; _udid = newValue }
    }
    public var runtime: String? {
        get { lock.lock(); defer { lock.unlock() }; return _runtime }
        set { lock.lock(); defer { lock.unlock() }; _runtime = newValue }
    }
    public init() {}
}

// MARK: - SimWire.Target helpers

extension SimWire.Target {
    /// Build a Target from tool parameters (ref+generation, label, or identifier).
    static func from(_ p: [String: Any]) -> SimWire.Target {
        SimWire.Target(ref: p["ref"] as? String,
                       label: p["label"] as? String,
                       identifier: p["identifier"] as? String,
                       generation: p["generation"] as? Int)
    }
}

// MARK: - Bundle ID resolution

/// Returns the resolved bundle ID, or an error AgentToolResult if none is available.
enum BundleIdResult {
    case resolved(String)
    case missing(AgentToolResult)
}

func resolveBundleId(_ p: [String: Any], _ session: SimSession, toolName: String) -> BundleIdResult {
    if let explicit = p["bundle_id"] as? String, !explicit.isEmpty { return .resolved(explicit) }
    if let current = session.currentBundleId { return .resolved(current) }
    return .missing(.error(toolCallId: "", toolName: toolName,
        message: "No app under test. Call sim_launch first, or pass bundle_id."))
}

// MARK: - SimUITool

public struct SimUITool: AgentTool {
    public let name = "sim_ui"
    public let description = """
    Read the current UI of the iOS simulator app as an accessibility tree — element \
    refs (e1, e2…), types, labels, values. Slimmed by default (interactive + labeled \
    elements); pass full:true for the complete tree. To locate ONE control, prefer \
    sim_find. ALWAYS prefer this over sim_screenshot. Refs are valid until the next snapshot.
    """
    public let parameters = ToolParameters(
        properties: [
            "bundle_id": ToolParameterProperty(type: "string",
                description: "App to inspect; defaults to the app launched via sim_launch."),
            "full": ToolParameterProperty(type: "boolean",
                description: "Return the complete tree. Default false = slimmed to interactive/labeled elements."),
        ],
        required: [])
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
            let tree = try await client.snapshot(bundleId: bundleId)
            let full = (parameters["full"] as? Bool) ?? false
            return .success(toolCallId: "", toolName: name,
                            result: full ? tree.renderCompact() : tree.renderSlim())
        } catch let e as SimDriverError {
            return .error(toolCallId: "", toolName: name,
                message: e.localizedDescription + (e.tree.map { "\n\nCurrent UI:\n" + $0.renderCompact() } ?? ""))
        } catch {
            return .error(toolCallId: "", toolName: name, message: "Unexpected error: \(error.localizedDescription)")
        }
    }
}

// MARK: - SimTapTool

public struct SimTapTool: AgentTool {
    public let name = "sim_tap"
    public let description = """
    Tap an element in the simulator. Target by `ref` + `generation` from the latest \
    sim_ui snapshot (preferred), or by `label`/`identifier`. Set long_press for a long press.
    """
    public let parameters = ToolParameters(
        properties: [
            "ref": ToolParameterProperty(type: "string", description: "Element ref from sim_ui, e.g. e12."),
            "generation": ToolParameterProperty(type: "integer", description: "Generation of the snapshot the ref came from."),
            "label": ToolParameterProperty(type: "string", description: "Exact accessibility label to tap (firstMatch)."),
            "identifier": ToolParameterProperty(type: "string", description: "Accessibility identifier to tap."),
            "long_press": ToolParameterProperty(type: "boolean", description: "Long-press instead of tap."),
            "bundle_id": ToolParameterProperty(type: "string", description: "Defaults to the launched app."),
        ],
        required: [])
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
            try await client.tap(bundleId: bundleId, target: .from(parameters),
                                 longPress: (parameters["long_press"] as? Bool) ?? false)
            return .success(toolCallId: "", toolName: name,
                result: "Tapped. Call sim_ui to see the resulting screen (or sim_wait for an expected element).")
        } catch let e as SimDriverError {
            return .error(toolCallId: "", toolName: name,
                message: e.localizedDescription + (e.tree.map { "\n\nCurrent UI:\n" + $0.renderCompact() } ?? ""))
        } catch {
            return .error(toolCallId: "", toolName: name, message: "Unexpected error: \(error.localizedDescription)")
        }
    }
}

// MARK: - SimTypeTool

public struct SimTypeTool: AgentTool {
    public let name = "sim_type"
    public let description = """
    Type text into the focused field (or a target element) in the simulator. \
    Optionally target by `ref`/`label`/`identifier` to focus first.
    """
    public let parameters = ToolParameters(
        properties: [
            "text": ToolParameterProperty(type: "string", description: "Text to type."),
            "ref": ToolParameterProperty(type: "string", description: "Element ref to focus before typing."),
            "generation": ToolParameterProperty(type: "integer", description: "Generation of the snapshot the ref came from."),
            "label": ToolParameterProperty(type: "string", description: "Accessibility label of element to focus."),
            "identifier": ToolParameterProperty(type: "string", description: "Accessibility identifier of element to focus."),
            "bundle_id": ToolParameterProperty(type: "string", description: "Defaults to the launched app."),
        ],
        required: ["text"])
    let client: any SimDriving
    let session: SimSession
    public init(client: any SimDriving, session: SimSession) { self.client = client; self.session = session }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let bundleId: String
        switch resolveBundleId(parameters, session, toolName: name) {
        case .missing(let e): return e
        case .resolved(let b): bundleId = b
        }
        guard let text = parameters["text"] as? String else {
            return .error(toolCallId: "", toolName: name, message: "sim_type requires `text`.")
        }
        let target: SimWire.Target? = (parameters["ref"] != nil || parameters["label"] != nil || parameters["identifier"] != nil)
            ? .from(parameters) : nil
        do {
            try await client.type(bundleId: bundleId, text: text, target: target)
            return .success(toolCallId: "", toolName: name, result: "Typed \"\(text)\".")
        } catch let e as SimDriverError {
            return .error(toolCallId: "", toolName: name,
                message: e.localizedDescription + (e.tree.map { "\n\nCurrent UI:\n" + $0.renderCompact() } ?? ""))
        } catch {
            return .error(toolCallId: "", toolName: name, message: "Unexpected error: \(error.localizedDescription)")
        }
    }
}

// MARK: - SimSwipeTool

public struct SimSwipeTool: AgentTool {
    public let name = "sim_swipe"
    public let description = """
    Swipe in a direction (up/down/left/right) on the simulator screen or a specific element.
    """
    public let parameters = ToolParameters(
        properties: [
            "direction": ToolParameterProperty(type: "string",
                description: "Swipe direction: up, down, left, or right.",
                enum: ["up", "down", "left", "right"]),
            "ref": ToolParameterProperty(type: "string", description: "Element ref to swipe on."),
            "generation": ToolParameterProperty(type: "integer", description: "Generation of the snapshot the ref came from."),
            "label": ToolParameterProperty(type: "string", description: "Accessibility label of element to swipe on."),
            "identifier": ToolParameterProperty(type: "string", description: "Accessibility identifier of element to swipe on."),
            "bundle_id": ToolParameterProperty(type: "string", description: "Defaults to the launched app."),
        ],
        required: ["direction"])
    let client: any SimDriving
    let session: SimSession
    public init(client: any SimDriving, session: SimSession) { self.client = client; self.session = session }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let bundleId: String
        switch resolveBundleId(parameters, session, toolName: name) {
        case .missing(let e): return e
        case .resolved(let b): bundleId = b
        }
        guard let direction = parameters["direction"] as? String else {
            return .error(toolCallId: "", toolName: name, message: "sim_swipe requires `direction`.")
        }
        let target: SimWire.Target? = (parameters["ref"] != nil || parameters["label"] != nil || parameters["identifier"] != nil)
            ? .from(parameters) : nil
        do {
            try await client.swipe(bundleId: bundleId, direction: direction, target: target)
            return .success(toolCallId: "", toolName: name, result: "Swiped \(direction).")
        } catch let e as SimDriverError {
            return .error(toolCallId: "", toolName: name,
                message: e.localizedDescription + (e.tree.map { "\n\nCurrent UI:\n" + $0.renderCompact() } ?? ""))
        } catch {
            return .error(toolCallId: "", toolName: name, message: "Unexpected error: \(error.localizedDescription)")
        }
    }
}

// MARK: - SimPressTool

public struct SimPressTool: AgentTool {
    public let name = "sim_press"
    public let description = """
    Press a hardware button on the simulator. Currently supports `home`.
    """
    public let parameters = ToolParameters(
        properties: [
            "button": ToolParameterProperty(type: "string",
                description: "Button to press (currently only 'home').",
                enum: ["home"]),
        ],
        required: ["button"])
    let client: any SimDriving
    public init(client: any SimDriving, session: SimSession) { self.client = client }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let button = (parameters["button"] as? String) ?? "home"
        do {
            switch button {
            case "home":
                try await client.pressHome()
                return .success(toolCallId: "", toolName: name, result: "Pressed Home button.")
            default:
                return .error(toolCallId: "", toolName: name, message: "Unknown button: \(button). Only 'home' is supported.")
            }
        } catch let e as SimDriverError {
            return .error(toolCallId: "", toolName: name,
                message: e.localizedDescription + (e.tree.map { "\n\nCurrent UI:\n" + $0.renderCompact() } ?? ""))
        } catch {
            return .error(toolCallId: "", toolName: name, message: "Unexpected error: \(error.localizedDescription)")
        }
    }
}

// MARK: - SimWaitTool

public struct SimWaitTool: AgentTool {
    public let name = "sim_wait"
    public let description = """
    Wait (event-driven, no polling) until an element exists — or disappears with \
    for_disappearance — then return the fresh UI tree. Use after taps that trigger \
    navigation or loading instead of repeated sim_ui calls.
    """
    public let parameters = ToolParameters(
        properties: [
            "label": ToolParameterProperty(type: "string", description: "Accessibility label to wait for."),
            "identifier": ToolParameterProperty(type: "string", description: "Accessibility identifier to wait for."),
            "timeout_seconds": ToolParameterProperty(type: "number", description: "Max wait in seconds, default 10, capped at 100."),
            "for_disappearance": ToolParameterProperty(type: "boolean", description: "Wait for the element to go away."),
            "bundle_id": ToolParameterProperty(type: "string", description: "Defaults to the launched app."),
        ],
        required: [])
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
            // Clamp to 100s: SimClient's URLSession request timeout is 120s; an uncapped
            // wait would misread as a transport failure and trigger a driver relaunch + duplicate wait.
            let requestedTimeout = (parameters["timeout_seconds"] as? Double) ?? 10
            let effectiveTimeout = min(requestedTimeout, 100)
            let tree = try await client.waitFor(bundleId: bundleId, target: .from(parameters),
                timeoutSeconds: effectiveTimeout,
                forDisappearance: (parameters["for_disappearance"] as? Bool) ?? false)
            return .success(toolCallId: "", toolName: name, result: tree.renderCompact())
        } catch let e as SimDriverError {
            return .error(toolCallId: "", toolName: name,
                message: e.localizedDescription + (e.tree.map { "\n\nCurrent UI:\n" + $0.renderCompact() } ?? ""))
        } catch {
            return .error(toolCallId: "", toolName: name, message: "Unexpected error: \(error.localizedDescription)")
        }
    }
}

// MARK: - SimAlertTool

public struct SimAlertTool: AgentTool {
    public let name = "sim_alert"
    public let description = """
    Accept or dismiss the currently visible system alert in the simulator \
    (permission dialogs, confirmations). Use `accept: true` to tap OK/Allow, \
    `accept: false` to tap Cancel/Deny.
    """
    public let parameters = ToolParameters(
        properties: [
            "accept": ToolParameterProperty(type: "boolean",
                description: "true to accept/allow the alert, false to dismiss/deny."),
        ],
        required: ["accept"])
    let client: any SimDriving
    let session: SimSession
    public init(client: any SimDriving, session: SimSession) { self.client = client; self.session = session }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let accept = (parameters["accept"] as? Bool) ?? true
        do {
            try await client.alert(accept: accept)
            return .success(toolCallId: "", toolName: name,
                result: accept ? "Alert accepted." : "Alert dismissed.")
        } catch let e as SimDriverError {
            return .error(toolCallId: "", toolName: name,
                message: e.localizedDescription + (e.tree.map { "\n\nCurrent UI:\n" + $0.renderCompact() } ?? ""))
        } catch {
            return .error(toolCallId: "", toolName: name, message: "Unexpected error: \(error.localizedDescription)")
        }
    }
}

// MARK: - SimFindTool

public struct SimFindTool: AgentTool {
    public let name = "sim_find"
    public let description = """
    Find elements without dumping the whole screen. `query` matches (case-insensitive \
    substring) against label, identifier, or value; optional `type` (e.g. button, textfield, \
    cell) and `tappable_only` narrow it. Returns up to 20 matches (hittable first) with refs \
    to pass to sim_tap. Prefer this over sim_ui when you know what you're looking for.
    """
    public let parameters = ToolParameters(
        properties: [
            "query": ToolParameterProperty(type: "string",
                description: "Text to find in label/identifier/value (case-insensitive substring)."),
            "type": ToolParameterProperty(type: "string",
                description: "Filter by element type, e.g. button, statictext, textfield, image, cell."),
            "tappable_only": ToolParameterProperty(type: "boolean", description: "Only tappable elements."),
            "bundle_id": ToolParameterProperty(type: "string", description: "Defaults to the launched app."),
        ],
        required: [])
    let client: any SimDriving
    let session: SimSession
    public init(client: any SimDriving, session: SimSession) { self.client = client; self.session = session }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        let bundleId: String
        switch resolveBundleId(parameters, session, toolName: name) {
        case .missing(let e): return e
        case .resolved(let b): bundleId = b
        }
        let query = (parameters["query"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let type = (parameters["type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let tappableOnly = (parameters["tappable_only"] as? Bool) ?? false
        guard query != nil || type != nil else {
            return .error(toolCallId: "", toolName: name,
                message: "Provide `query` or `type`; use sim_ui to see the whole screen.")
        }
        do {
            let tree = try await client.snapshot(bundleId: bundleId)
            return .success(toolCallId: "", toolName: name,
                result: Self.renderMatches(in: tree, query: query, type: type, tappableOnly: tappableOnly))
        } catch let e as SimDriverError {
            return .error(toolCallId: "", toolName: name,
                message: e.localizedDescription + (e.tree.map { "\n\nCurrent UI:\n" + $0.renderCompact() } ?? ""))
        } catch {
            return .error(toolCallId: "", toolName: name, message: "Unexpected error: \(error.localizedDescription)")
        }
    }

    /// Pure: matches in document order, then stable-partitioned hittable-first.
    public static func matches(in tree: UITree, query: String?, type: String?, tappableOnly: Bool) -> [UINode] {
        let q = query?.lowercased(); let t = type?.lowercased()
        func field(_ s: String?) -> Bool { guard let q else { return false }; return (s ?? "").lowercased().contains(q) }
        var found: [UINode] = []
        func walk(_ n: UINode) {
            let mq = q == nil || field(n.label) || field(n.identifier) || field(n.value)
            let mt = t == nil || n.typeName.lowercased().contains(t!)
            let mh = !tappableOnly || n.isHittable
            if mq && mt && mh { found.append(n) }
            n.children.forEach(walk)
        }
        walk(tree.root)
        return found.filter { $0.isHittable } + found.filter { !$0.isHittable }   // stable: hittable first
    }

    public static func renderMatches(in tree: UITree, query: String?, type: String?, tappableOnly: Bool) -> String {
        let all = matches(in: tree, query: query, type: type, tappableOnly: tappableOnly)
        if all.isEmpty {
            let what = query.map { "\"\($0)\"" } ?? "type \(type ?? "")"
            return "No elements match \(what). Call sim_ui to see the whole screen."
        }
        var out = "UI of \(tree.bundleId) — generation \(tree.generation)\n"
        for n in all.prefix(20) {
            var line = "\(n.ref) \(n.typeName)"
            if let l = n.label { line += " \"\(l)\"" }
            if let i = n.identifier { line += " id=\(i)" }
            if let v = n.value { line += " value=\(v)" }
            if n.isHittable { line += " [tappable]" }
            out += line + "\n"
        }
        if all.count > 20 { out += "… +\(all.count - 20) more — refine query\n" }
        return out
    }
}

// MARK: - makeSimulatorTools

/// Returns the full set of simulator tools (15) for one-call agent registration.
public func makeSimulatorTools(session: SimSession, client: any SimDriving) -> [any AgentTool] {
    [SimListTool(), SimBootTool(session: session),
     SimLaunchTool(client: client, session: session), SimTerminateTool(client: client, session: session),
     SimUITool(client: client, session: session), SimFindTool(client: client, session: session),
     SimTapTool(client: client, session: session),
     SimTypeTool(client: client, session: session), SimSwipeTool(client: client, session: session),
     SimPressTool(client: client, session: session), SimWaitTool(client: client, session: session),
     SimAlertTool(client: client, session: session), SimScreenshotTool(client: client, session: session),
     SimBuildInstallTool(session: session), SimLogsTool(session: session)]
}
#endif
