//
//  SimWire.swift — CANONICAL COPY.
//  A byte-identical copy lives at Resources/SimDriverProject/SimDriverUITests/SimWire.swift
//  (the driver Xcode project compiles that one). SimWireSyncTests enforces identity.
//
import Foundation

/// A Codable/Equatable representation of a rectangle frame.
public struct CGRectCodable: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// Convert from a standard CGRect (used in tests and bridging).
    public init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.size.width)
        self.height = Double(rect.size.height)
    }

    /// Convert to a standard CGRect for compatibility.
    public var cgRect: CGRect {
        CGRect(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height))
    }

    /// Create from standard CGPoint and CGSize.
    static var zero: CGRectCodable {
        CGRectCodable(x: 0, y: 0, width: 0, height: 0)
    }
}

/// One element in the accessibility hierarchy.
public struct UINode: Codable, Sendable, Equatable {
    public var ref: String
    public var type: String        // XCUIElement.ElementType description, e.g. "Button"
    public var label: String?
    public var identifier: String?
    public var value: String?
    public var frame: CGRectCodable
    public var isHittable: Bool
    public var isEnabled: Bool
    public var children: [UINode]

    public init(ref: String, type: String, label: String?, identifier: String?, value: String?,
                frame: CGRectCodable, isHittable: Bool, isEnabled: Bool, children: [UINode]) {
        self.ref = ref; self.type = type; self.label = label; self.identifier = identifier
        self.value = value; self.frame = frame; self.isHittable = isHittable
        self.isEnabled = isEnabled; self.children = children
    }

    /// A node worth showing the model: named, valued, interactive, or structural (has kept children).
    var isRenderable: Bool {
        label != nil || identifier != nil || value != nil || isHittable
            || frame.width * frame.height > 0
    }
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
