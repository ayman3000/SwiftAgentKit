#if os(macOS)
import Foundation
import CoreGraphics   // CGRect Codable/Equatable conformance lives in the CoreGraphics overlay

public struct UINode: Codable, Sendable, Equatable {
    public var ref: String
    public var role: String
    public var title: String?
    public var identifier: String?
    public var value: String?
    public var frame: CGRect
    public var isEnabled: Bool
    public var actions: [String]
    public var children: [UINode]

    public init(ref: String, role: String, title: String?, identifier: String?, value: String?,
                frame: CGRect, isEnabled: Bool, actions: [String], children: [UINode]) {
        self.ref = ref; self.role = role; self.title = title; self.identifier = identifier
        self.value = value; self.frame = frame; self.isEnabled = isEnabled
        self.actions = actions; self.children = children
    }

    var isRenderable: Bool {
        title != nil || identifier != nil || value != nil || !actions.isEmpty
            || frame.width * frame.height > 0
    }
}

public struct UITree: Codable, Sendable, Equatable {
    public var generation: Int
    public var bundleId: String
    public var root: UINode
    public init(generation: Int, bundleId: String, root: UINode) {
        self.generation = generation; self.bundleId = bundleId; self.root = root
    }

    public func renderCompact() -> String {
        var out = "UI of \(bundleId) — generation \(generation)\n"
        func walk(_ node: UINode, depth: Int) {
            let kept = node.children.filter { $0.isRenderable || !$0.children.isEmpty }
            guard node.isRenderable || !kept.isEmpty else { return }
            var line = String(repeating: "  ", count: depth) + "\(node.ref) \(node.role)"
            if let t = node.title { line += " \"\(t)\"" }
            if let i = node.identifier { line += " id=\(i)" }
            if let v = node.value { line += " value=\(v)" }
            if !node.isEnabled { line += " (disabled)" }
            if !node.actions.isEmpty { line += " [\(node.actions.joined(separator: ","))]" }
            out += line + "\n"
            kept.forEach { walk($0, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return out
    }
}

public struct MacTarget: Codable, Sendable, Equatable {
    public var ref: String?
    public var title: String?
    public var identifier: String?
    public var generation: Int?
    public init(ref: String? = nil, title: String? = nil, identifier: String? = nil, generation: Int? = nil) {
        self.ref = ref; self.title = title; self.identifier = identifier; self.generation = generation
    }
}

public struct MacDriverError: Error, LocalizedError, Sendable {
    public var code: String
    public var message: String
    public var tree: UITree?
    public var errorDescription: String? { "\(code): \(message)" }
    public init(code: String, message: String, tree: UITree? = nil) {
        self.code = code; self.message = message; self.tree = tree
    }
}
#endif
