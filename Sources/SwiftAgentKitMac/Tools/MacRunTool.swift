#if os(macOS)
import Foundation
import SwiftAgentKit

/// One step of a `mac_run` batch. Same vocabulary as the single mac_* tools.
struct MacRunStep: Equatable {
    enum Action: String, CaseIterable {
        case click, double_click, right_click, choose, type, key, scroll, wait, launch
    }
    var item: String?
    var action: Action
    var target: MacTarget?
    var text: String?
    var keys: String?
    var replace = false
    var direction: String?
    var amount = 10
    var timeoutSeconds = 10.0
    var forDisappearance = false

    struct ParseError: Error { let message: String }

    /// Parse one step object; a message on failure.
    static func parse(_ raw: Any, index: Int) -> Result<MacRunStep, ParseError> {
        guard let p = raw as? [String: Any] else { return .failure(ParseError(message: "step \(index + 1) is not an object")) }
        guard let name = p["action"] as? String, let action = Action(rawValue: name.lowercased()) else {
            return .failure(ParseError(message: "step \(index + 1): unknown action '\(p["action"] ?? "")' — use "
                            + Action.allCases.map(\.rawValue).joined(separator: ", ")))
        }
        var s = MacRunStep(action: action)
        let t = MacTarget.from(p)
        s.target = (t.ref != nil || t.title != nil || t.identifier != nil) ? t : nil
        s.item = p["item"] as? String
        s.text = p["text"] as? String
        s.keys = p["keys"] as? String
        s.replace = (p["replace"] as? Bool) ?? false
        s.direction = p["direction"] as? String
        s.amount = (p["amount"] as? Int) ?? Int((p["amount"] as? Double) ?? 10)
        s.timeoutSeconds = (p["timeout_seconds"] as? Double) ?? Double((p["timeout_seconds"] as? Int) ?? 10)
        s.forDisappearance = (p["for_disappearance"] as? Bool) ?? false
        switch action {
        case .click, .double_click, .right_click:
            if s.target == nil { return .failure(ParseError(message: "step \(index + 1) (\(name)): needs ref+generation, title or identifier")) }
        case .choose:
            if s.target == nil || s.item == nil { return .failure(ParseError(message: "step \(index + 1) (choose): needs the pop-up's ref/title/identifier and `item`")) }
        case .type:
            if s.text == nil { return .failure(ParseError(message: "step \(index + 1) (type): needs text")) }
        case .key:
            if s.keys == nil { return .failure(ParseError(message: "step \(index + 1) (key): needs keys")) }
        case .scroll:
            if s.direction == nil { return .failure(ParseError(message: "step \(index + 1) (scroll): needs direction")) }
        case .wait:
            if s.target == nil { return .failure(ParseError(message: "step \(index + 1) (wait): needs title or identifier")) }
        case .launch:
            break
        }
        return .success(s)
    }

    var summary: String {
        var parts = [action.rawValue]
        if let t = target { parts.append(t.ref ?? t.title ?? t.identifier ?? "") }
        if let item { parts.append("→ \(item)") }
        if let text { parts.append("\"\(text.prefix(40))\(text.count > 40 ? "…" : "")\"") }
        if let keys { parts.append(keys) }
        if let direction { parts.append("\(direction) \(amount)") }
        return parts.joined(separator: " ")
    }
}

/// Runs several Mac actions in one call — the model states what it already
/// knows it will do next, and pays one round trip instead of one per step.
public struct MacRunTool: AgentTool {
    public let name = "mac_run"
    public let description = """
    Run several actions in ONE call on a native macOS app, in order, stopping at the \
    first one that fails. Use it whenever you already know the next few steps (open a \
    menu, click an item, type, press Return, wait for a result): one call instead of \
    one per step. Each step is an object with `action` = click | double_click | \
    right_click | choose | type | key | scroll | wait | launch, plus the same fields the \
    single tools take (ref+generation, title, identifier, item, text, replace, keys, \
    direction, amount, timeout_seconds, for_disappearance). `choose` opens a pop-up or \
    menu button and picks `item` by title in one step — use it for Save-sheet formats \
    and settings instead of arrow keys. Typing and clicks are verified exactly \
    as in mac_type and mac_click. Refs from your last mac_ui are valid until a `wait` \
    step (which re-reads the window); after that target by title or identifier. The \
    result lists what each step did and ends with the window as it is now, so you do \
    not need a separate mac_ui afterwards.
    """
    public let parameters = ToolParameters(
        properties: [
            "bundle_id": ToolParameterProperty(
                type: "string",
                description: "Bundle id of the target app (see mac_apps)."),
            "steps": ToolParameterProperty(
                type: "array",
                description: "Ordered steps, e.g. [{\"action\":\"key\",\"keys\":\"cmd+n\"}, {\"action\":\"type\",\"text\":\"Hello\"}, {\"action\":\"wait\",\"title\":\"Untitled\"}]"),
            "read_after": ToolParameterProperty(
                type: "boolean",
                description: "Append the window's accessibility tree after the last step (default true)."),
            "filter": ToolParameterProperty(
                type: "string",
                description: "With read_after: only elements whose text contains this, to keep the result small."),
        ],
        required: ["bundle_id", "steps"])
    public var requiresConfirmation: Bool { true }

    let client: any AXDriving
    let allowlistProvider: @Sendable () -> Set<String>

    public init(client: any AXDriving, allowlistProvider: @escaping @Sendable () -> Set<String>) {
        self.client = client
        self.allowlistProvider = allowlistProvider
    }

    /// Upper bound so a runaway plan cannot act for minutes unattended.
    public static let maxSteps = 12

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        if let err = accessibilityError(toolName: name, client: client) { return err }
        let bundleId: String
        switch AllowlistGuard.resolve(parameters, allowlist: allowlistProvider(), toolName: name) {
        case .failure(let e): return e
        case .success(let b): bundleId = b
        }
        guard let rawSteps = parameters["steps"] as? [Any], !rawSteps.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "mac_run requires a non-empty `steps` array.")
        }
        guard rawSteps.count <= Self.maxSteps else {
            return .error(toolCallId: "", toolName: name, message: "mac_run takes at most \(Self.maxSteps) steps per call; split the plan.")
        }
        var steps: [MacRunStep] = []
        for (i, raw) in rawSteps.enumerated() {
            switch MacRunStep.parse(raw, index: i) {
            case .success(let s): steps.append(s)
            case .failure(let e): return .error(toolCallId: "", toolName: name, message: e.message)
            }
        }
        let readAfter = (parameters["read_after"] as? Bool) ?? true
        let filter = (parameters["filter"] as? String)?.trimmingCharacters(in: .whitespaces)

        var report: [String] = []
        var lastTree: UITree?
        for (i, step) in steps.enumerated() {
            do {
                let outcome = try await run(step, bundleId: bundleId, lastTree: &lastTree)
                report.append("\(i + 1). \(step.summary) → \(outcome)")
                if step.action != .wait { try await Task.sleep(nanoseconds: 150_000_000) }   // let the UI settle
            } catch let e as MacDriverError {
                report.append("\(i + 1). \(step.summary) → FAILED: \(e.localizedDescription)")
                let rest = steps.count - i - 1
                if rest > 0 { report.append("Stopped; \(rest) step\(rest == 1 ? "" : "s") not run.") }
                let tree = e.tree.map { "\n\nCurrent UI:\n" + $0.renderCompact() } ?? ""
                return .error(toolCallId: "", toolName: name, message: report.joined(separator: "\n") + tree)
            } catch {
                report.append("\(i + 1). \(step.summary) → FAILED: \(error.localizedDescription)")
                return .error(toolCallId: "", toolName: name, message: report.joined(separator: "\n"))
            }
        }
        var text = report.joined(separator: "\n")
        if readAfter {
            let tree: UITree
            if let lastTree { tree = lastTree } else { tree = try await client.snapshot(bundleId: bundleId) }
            if let filter, !filter.isEmpty { text += "\n\n" + tree.renderMatches(filter) }
            else { text += "\n\n" + tree.renderCompact() }
        }
        return .success(toolCallId: "", toolName: name, result: text)
    }

    private func run(_ step: MacRunStep, bundleId: String, lastTree: inout UITree?) async throws -> String {
        switch step.action {
        case .click:
            return try await client.click(bundleId: bundleId, target: step.target!, options: MacClickOptions())
        case .double_click:
            return try await client.click(bundleId: bundleId, target: step.target!, options: MacClickOptions(clicks: 2))
        case .right_click:
            return try await client.click(bundleId: bundleId, target: step.target!, options: MacClickOptions(rightButton: true))
        case .choose:
            return try await client.choose(bundleId: bundleId, target: step.target!, item: step.item!)
        case .type:
            let verified = try await client.type(bundleId: bundleId, text: step.text!, target: step.target, replace: step.replace)
            return verified ? "typed, verified" : "typed (field not readable)"
        case .key:
            try await client.key(bundleId: bundleId, keys: step.keys!)
            return "sent"
        case .scroll:
            try await client.scroll(bundleId: bundleId, target: step.target, direction: step.direction!, amount: step.amount)
            return "scrolled"
        case .wait:
            lastTree = try await client.waitFor(bundleId: bundleId, target: step.target!,
                                                timeoutSeconds: step.timeoutSeconds, forDisappearance: step.forDisappearance)
            return step.forDisappearance ? "gone" : "appeared"
        case .launch:
            try await client.launch(bundleId: bundleId)
            return "launched"
        }
    }
}

#endif
