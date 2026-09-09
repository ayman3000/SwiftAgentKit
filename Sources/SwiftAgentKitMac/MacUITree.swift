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

    public var isRenderable: Bool {
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

    private func hasRenderableSubtree(_ node: UINode) -> Bool {
        node.isRenderable || node.children.contains(where: hasRenderableSubtree)
    }

    /// Rows a single table/outline/list may show before the rest is summarised.
    /// A file manager pane can hold hundreds of rows; the model needs to see the
    /// shape and a good sample, and can still target any row by its text.
    public static let maxRowsPerContainer = 60

    /// Roles that are pure layout: they get no line of their own when they carry
    /// no title, identifier, value or action — their children are hoisted.
    static let wrapperRoles: Set<String> = ["AXGroup", "AXCell", "AXGenericElement", "AXUnknown"]

    /// Roles the user can operate; a row containing one is rendered in full.
    static let interactiveRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXMenuButton", "AXComboBox", "AXSlider", "AXDisclosureTriangle",
        "AXLink", "AXIncrementor", "AXSwitch", "AXToggle", "AXColorWell", "AXSearchField",
    ]

    private func isWrapper(_ node: UINode) -> Bool {
        Self.wrapperRoles.contains(node.role) && node.title == nil && node.identifier == nil
            && node.value == nil && node.actions.isEmpty
    }

    private func containsInteractive(_ node: UINode) -> Bool {
        node.children.contains { Self.interactiveRoles.contains($0.role) || containsInteractive($0) }
    }

    /// The visible text of a subtree, in document order: titles and values of leaves.
    private func leafTexts(_ node: UINode) -> [String] {
        var out: [String] = []
        func walk(_ n: UINode) {
            if n.children.isEmpty {
                if let t = n.title, !t.isEmpty { out.append(t) }
                if let v = n.value, !v.isEmpty, v != n.title { out.append(v) }
            } else {
                n.children.forEach(walk)
            }
        }
        walk(node)
        return out
    }

    private func describe(_ node: UINode) -> String {
        var line = "\(node.ref) \(node.role)"
        if let t = node.title { line += " \"\(t)\"" }
        if let i = node.identifier { line += " id=\(i)" }
        if let v = node.value { line += " value=\(v)" }
        if !node.isEnabled { line += " (disabled)" }
        if !node.actions.isEmpty { line += " [\(node.actions.joined(separator: ", "))]" }
        return line
    }

    /// Compact text for the model. Three reductions keep a data-heavy window
    /// (a file manager, a mail list) to a few hundred lines instead of thousands:
    /// layout wrappers get no line, a plain table row becomes one line of its
    /// cell texts, and a container shows at most `maxRowsPerContainer` rows.
    /// - Parameter includeMenus: expand the menu bar's menus. Off by default: the
    ///   menus are the same in every snapshot and cost hundreds of lines; a menu
    ///   item can still be clicked by title without being listed.
    public func renderCompact(includeMenus: Bool = false) -> String {
        var out = "UI of \(bundleId) — generation \(generation)\n"
        func emit(_ text: String, _ depth: Int) { out += String(repeating: "  ", count: depth) + text + "\n" }

        func walk(_ node: UINode, depth: Int) {
            let kept = node.children.filter(hasRenderableSubtree)
            guard node.isRenderable || !kept.isEmpty else { return }

            // Menu bar: one line naming the menus, unless the caller asked for the items.
            if node.role == "AXMenuBar" && !includeMenus {
                let titles = node.children.compactMap(\.title).filter { !$0.isEmpty }
                emit("\(node.ref) AXMenuBar: " + titles.joined(separator: " | ")
                     + " (menu items not listed; click one by its title, or pass include_menus:true to mac_ui)", depth)
                return
            }

            // Layout-only wrapper: hoist the children, spend no line.
            if isWrapper(node) {
                renderChildren(kept, depth: depth)
                return
            }
            // Plain data row: one line of its texts, the row's ref stays clickable.
            if node.role == "AXRow" && !containsInteractive(node) {
                let texts = leafTexts(node)
                var line = "\(node.ref) AXRow"
                if !texts.isEmpty { line += ": " + texts.joined(separator: " | ") }
                if !node.isEnabled { line += " (disabled)" }
                if !node.actions.isEmpty { line += " [\(node.actions.joined(separator: ", "))]" }
                emit(line, depth)
                return
            }
            emit(describe(node), depth)
            renderChildren(kept, depth: depth + 1)
        }

        func renderChildren(_ children: [UINode], depth: Int) {
            var rowsShown = 0
            var rowsHidden = 0
            for child in children {
                if child.role == "AXRow" {
                    if rowsShown >= Self.maxRowsPerContainer { rowsHidden += 1; continue }
                    rowsShown += 1
                }
                walk(child, depth: depth)
            }
            if rowsHidden > 0 {
                emit("… \(rowsHidden) more rows not shown. Any row can still be targeted: pass its text as "
                     + "`title` to mac_click or mac_wait.", depth)
            }
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
