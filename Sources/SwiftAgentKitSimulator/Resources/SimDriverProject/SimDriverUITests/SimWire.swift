//
//  SimWire.swift — CANONICAL COPY.
//  A byte-identical copy lives at Resources/SimDriverProject/SimDriverUITests/SimWire.swift
//  (the driver Xcode project compiles that one). SimWireSyncTests enforces identity.
//
import Foundation
import CoreGraphics

/// One element in the accessibility hierarchy.
public struct UINode: Codable, Sendable, Equatable {
    public var ref: String
    public var type: String        // XCUIElement.ElementType description, e.g. "Button"
    public var label: String?
    public var identifier: String?
    public var value: String?
    public var frame: CGRect
    public var isHittable: Bool
    public var isEnabled: Bool
    public var children: [UINode]

    public init(ref: String, type: String, label: String?, identifier: String?, value: String?,
                frame: CGRect, isHittable: Bool, isEnabled: Bool, children: [UINode]) {
        self.ref = ref; self.type = type; self.label = label; self.identifier = identifier
        self.value = value; self.frame = frame; self.isHittable = isHittable
        self.isEnabled = isEnabled; self.children = children
    }

    /// A node worth showing the model: named, valued, interactive, or structural (has kept children).
    var isRenderable: Bool {
        label != nil || identifier != nil || value != nil || isHittable
            || frame.width * frame.height > 0
    }

    /// Human-friendly element type derived from the raw XCUIElementType string
    /// ("XCUIElementType(rawValue: 9)" → "Button"). The host can't import XCTest, so this
    /// maps the stable rawValues; unknown values fall back to the raw string.
    public var typeName: String {
        guard let raw = UINode.rawTypeValue(from: type),
              let name = UINode.typeNames[raw] else { return type }
        return name
    }

    static func rawTypeValue(from typeString: String) -> Int? {
        guard let r = typeString.range(of: "rawValue: ") else { return nil }
        let digits = typeString[r.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    static let typeNames: [Int: String] = [
        0: "Any", 1: "Other", 2: "Application", 3: "Group", 4: "Window", 5: "Sheet",
        6: "Drawer", 7: "Alert", 8: "Dialog", 9: "Button", 10: "RadioButton",
        11: "RadioGroup", 12: "CheckBox", 13: "DisclosureTriangle", 14: "PopUpButton",
        15: "ComboBox", 16: "MenuButton", 17: "ToolbarButton", 18: "Popover",
        19: "Keyboard", 20: "Key", 21: "NavigationBar", 22: "TabBar", 23: "TabGroup",
        24: "Toolbar", 25: "StatusBar", 26: "Table", 27: "TableRow", 28: "TableColumn",
        29: "Outline", 30: "OutlineRow", 31: "Browser", 32: "CollectionView", 33: "Slider",
        34: "PageIndicator", 35: "ProgressIndicator", 36: "ActivityIndicator",
        37: "SegmentedControl", 38: "Picker", 39: "PickerWheel", 40: "Switch", 41: "Toggle",
        42: "Link", 43: "Image", 44: "Icon", 45: "SearchField", 46: "ScrollView",
        47: "ScrollBar", 48: "StaticText", 49: "TextField", 50: "SecureTextField",
        51: "DatePicker", 52: "TextView", 53: "Menu", 54: "MenuItem", 55: "MenuBar",
        56: "MenuBarItem", 57: "Map", 58: "WebView", 59: "IncrementArrow", 60: "DecrementArrow",
        61: "Timeline", 62: "RatingIndicator", 63: "ValueIndicator", 64: "SplitGroup",
        65: "Splitter", 66: "RelevanceIndicator", 67: "ColorWell", 68: "HelpTag", 69: "Matte",
        70: "DockItem", 71: "Ruler", 72: "RulerMarker", 73: "Grid", 74: "LevelIndicator",
        75: "Cell", 76: "LayoutArea", 77: "LayoutItem", 78: "Handle", 79: "Stepper",
        80: "Tab", 81: "TouchBar", 82: "StatusItem",
    ]
}

public struct UITree: Codable, Sendable, Equatable {
    /// Monotonic snapshot counter; refs are only valid for the generation they came from.
    public var generation: Int
    public var bundleId: String
    public var root: UINode

    public init(generation: Int, bundleId: String, root: UINode) {
        self.generation = generation; self.bundleId = bundleId; self.root = root
    }

    /// Compact indented text for the LLM. Prunes anonymous zero-size leaves.
    public func renderCompact() -> String {
        var out = "UI of \(bundleId) — generation \(generation)\n"
        func walk(_ node: UINode, depth: Int) {
            let kept = node.children.filter { $0.isRenderable || !$0.children.isEmpty }
            guard node.isRenderable || !kept.isEmpty else { return }
            var line = String(repeating: "  ", count: depth) + "\(node.ref) \(node.type)"
            if let l = node.label { line += " \"\(l)\"" }
            if let i = node.identifier { line += " id=\(i)" }
            if let v = node.value { line += " value=\(v)" }
            if !node.isEnabled { line += " (disabled)" }
            if node.isHittable { line += " [tappable]" }
            out += line + "\n"
            kept.forEach { walk($0, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return out
    }

    /// A slimmed render for the model: pure-structural containers (no label/value/identifier
    /// and not an interactive leaf) are dropped and their kept descendants reparented upward,
    /// so deep wrapper nesting collapses. Interactive leaves and all labeled/valued/identified
    /// nodes are always kept. Uses friendly `typeName`. `renderCompact` is unchanged.
    public func renderSlim() -> String {
        var out = "UI of \(bundleId) — generation \(generation)\n"
        func anyKeptBelow(_ n: UINode) -> Bool {
            n.children.contains { isKept($0) || anyKeptBelow($0) }
        }
        func isKept(_ n: UINode) -> Bool {
            if n.label != nil || n.identifier != nil || n.value != nil { return true }
            return n.isHittable && !anyKeptBelow(n)   // interactive leaf
        }
        func line(_ n: UINode, _ depth: Int) -> String {
            var s = String(repeating: "  ", count: depth) + "\(n.ref) \(n.typeName)"
            if let l = n.label { s += " \"\(l)\"" }
            if let i = n.identifier { s += " id=\(i)" }
            if let v = n.value { s += " value=\(v)" }
            if !n.isEnabled { s += " (disabled)" }
            if n.isHittable { s += " [tappable]" }
            return s
        }
        func walk(_ n: UINode, _ depth: Int) {
            if isKept(n) {
                out += line(n, depth) + "\n"
                n.children.forEach { walk($0, depth + 1) }
            } else {
                n.children.forEach { walk($0, depth) }   // flatten
            }
        }
        walk(root, 0)
        return out
    }
}

/// Request/response bodies shared by host and driver. All POST bodies are JSON.
public enum SimWire {
    /// Target an element by snapshot ref, or by label/identifier query (firstMatch).
    public struct Target: Codable, Sendable, Equatable {
        public var ref: String?
        public var label: String?
        public var identifier: String?
        public var generation: Int?   // required with ref; driver rejects stale generations
        public init(ref: String? = nil, label: String? = nil, identifier: String? = nil, generation: Int? = nil) {
            self.ref = ref; self.label = label; self.identifier = identifier; self.generation = generation
        }
    }
    public struct TapRequest: Codable, Sendable, Equatable {
        public var bundleId: String; public var target: Target; public var longPress: Bool
        public init(bundleId: String, target: Target, longPress: Bool = false) {
            self.bundleId = bundleId; self.target = target; self.longPress = longPress
        }
    }
    public struct TypeRequest: Codable, Sendable, Equatable {
        public var bundleId: String; public var text: String; public var target: Target?
        public init(bundleId: String, text: String, target: Target? = nil) {
            self.bundleId = bundleId; self.text = text; self.target = target
        }
    }
    public struct SwipeRequest: Codable, Sendable, Equatable {
        public var bundleId: String; public var direction: String  // up/down/left/right
        public var target: Target?
        public init(bundleId: String, direction: String, target: Target? = nil) {
            self.bundleId = bundleId; self.direction = direction; self.target = target
        }
    }
    public struct PressRequest: Codable, Sendable, Equatable {
        public var button: String   // "home"
        public init(button: String) { self.button = button }
    }
    public struct WaitRequest: Codable, Sendable, Equatable {
        public var bundleId: String; public var target: Target; public var timeoutSeconds: Double
        public var forDisappearance: Bool
        public init(bundleId: String, target: Target, timeoutSeconds: Double, forDisappearance: Bool = false) {
            self.bundleId = bundleId; self.target = target
            self.timeoutSeconds = timeoutSeconds; self.forDisappearance = forDisappearance
        }
    }
    public struct AlertRequest: Codable, Sendable, Equatable {
        public var accept: Bool
        public init(accept: Bool) { self.accept = accept }
    }
    public struct LaunchRequest: Codable, Sendable, Equatable {
        public var bundleId: String; public var terminateFirst: Bool
        public init(bundleId: String, terminateFirst: Bool = false) {
            self.bundleId = bundleId; self.terminateFirst = terminateFirst
        }
    }
    public struct TreeResponse: Codable, Sendable, Equatable {
        public var tree: UITree
        public init(tree: UITree) { self.tree = tree }
    }
    public struct OKResponse: Codable, Sendable, Equatable {
        public var ok: Bool
        public init(ok: Bool = true) { self.ok = ok }
    }
    /// Non-2xx body. `tree` carries current state on wait-timeout so the model sees reality.
    public struct ErrorResponse: Codable, Sendable, Equatable {
        public var code: String      // "stale_ref" | "not_found" | "timeout" | "bad_request" | "internal"
        public var message: String
        public var tree: UITree?
        public init(code: String, message: String, tree: UITree? = nil) {
            self.code = code; self.message = message; self.tree = tree
        }
    }
}
