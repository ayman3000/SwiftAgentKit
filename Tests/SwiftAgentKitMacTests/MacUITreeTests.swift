#if os(macOS)
import XCTest
@testable import SwiftAgentKitMac

final class MacUITreeTests: XCTestCase {
    private func sampleTree() -> UITree {
        let save = UINode(ref: "e2", role: "AXButton", title: "Save", identifier: "save_btn",
                          value: nil, frame: .init(x: 10, y: 100, width: 80, height: 24),
                          isEnabled: true, actions: ["AXPress"], children: [])
        let hidden = UINode(ref: "e3", role: "AXGroup", title: nil, identifier: nil, value: nil,
                            frame: .zero, isEnabled: true, actions: [], children: [])
        let win = UINode(ref: "e1", role: "AXWindow", title: "Untitled", identifier: nil, value: nil,
                         frame: .init(x: 0, y: 0, width: 800, height: 600),
                         isEnabled: true, actions: [], children: [save, hidden])
        return UITree(generation: 5, bundleId: "com.apple.TextEdit", root: win)
    }

    func testRoundTripsThroughJSON() throws {
        let tree = sampleTree()
        let back = try JSONDecoder().decode(UITree.self, from: JSONEncoder().encode(tree))
        XCTAssertEqual(back, tree)
    }

    func testRenderShowsRefRoleTitleActionsAndGeneration() {
        let text = sampleTree().renderCompact()
        XCTAssertTrue(text.contains("generation 5"))
        XCTAssertTrue(text.contains(#"e2 AXButton "Save" id=save_btn"#))
        XCTAssertTrue(text.contains("[AXPress]"))
    }

    func testRenderPrunesAnonymousEmptyLeaf() {
        XCTAssertFalse(sampleTree().renderCompact().contains("e3"))
    }

    func testRenderIndentsChildren() {
        let lines = sampleTree().renderCompact().split(separator: "\n")
        XCTAssertTrue(lines.first { $0.contains("e2") }!.hasPrefix("  "))
    }

    func testRenderPrunesNestedAnonymousGroups() {
        let deep = UINode(ref: "g2", role: "AXGroup", title: nil, identifier: nil, value: nil,
                          frame: .zero, isEnabled: true, actions: [], children: [])
        let mid = UINode(ref: "g1", role: "AXGroup", title: nil, identifier: nil, value: nil,
                         frame: .zero, isEnabled: true, actions: [], children: [deep])
        let root = UINode(ref: "e1", role: "AXWindow", title: "W", identifier: nil, value: nil,
                          frame: .init(x: 0, y: 0, width: 10, height: 10),
                          isEnabled: true, actions: [], children: [mid])
        let text = UITree(generation: 1, bundleId: "x", root: root).renderCompact()
        XCTAssertFalse(text.contains("g1")); XCTAssertFalse(text.contains("g2"))
        XCTAssertTrue(text.contains("e1"))
    }

    // MARK: - Data-heavy windows

    private func text(_ ref: String, _ value: String) -> UINode {
        UINode(ref: ref, role: "AXStaticText", title: nil, identifier: nil, value: value,
               frame: .init(x: 0, y: 0, width: 100, height: 16), isEnabled: true, actions: [], children: [])
    }
    private func wrap(_ ref: String, _ role: String, _ children: [UINode]) -> UINode {
        UINode(ref: ref, role: role, title: nil, identifier: nil, value: nil,
               frame: .init(x: 0, y: 0, width: 400, height: 16), isEnabled: true, actions: [], children: children)
    }
    /// A file-manager row as macOS exposes it: row > cell > group > text, four columns.
    private func fileRow(_ n: Int, name: String) -> UINode {
        let base = n * 20
        let cells = [name, "122 KB", "PNG image", "15 Jun 2026"].enumerated().map { i, v in
            wrap("e\(base + 2 + i * 3)", "AXCell", [wrap("e\(base + 3 + i * 3)", "AXGroup", [text("e\(base + 4 + i * 3)", v)])])
        }
        return UINode(ref: "e\(base)", role: "AXRow", title: nil, identifier: nil, value: nil,
                      frame: .init(x: 0, y: 0, width: 400, height: 16), isEnabled: true,
                      actions: ["AXShowDefaultUI"], children: [wrap("e\(base + 1)", "AXCell", [])] + cells)
    }
    private func table(rows: Int) -> UITree {
        let outline = UINode(ref: "e1", role: "AXOutline", title: nil, identifier: nil, value: nil,
                             frame: .init(x: 0, y: 0, width: 400, height: 600), isEnabled: true,
                             actions: ["AXShowMenu"], children: (1...rows).map { fileRow($0, name: "file\($0).png") })
        return UITree(generation: 1, bundleId: "app", root: outline)
    }

    func testPlainRowCollapsesToOneLineOfItsTexts() {
        let text = table(rows: 1).renderCompact()
        XCTAssertTrue(text.contains("e20 AXRow: file1.png | 122 KB | PNG image | 15 Jun 2026 [AXShowDefaultUI]"), text)
        XCTAssertFalse(text.contains("AXCell"))
        XCTAssertFalse(text.contains("AXGroup"))
        XCTAssertEqual(text.split(separator: "\n").count, 3)   // header, outline, row
    }

    func testRowsBeyondCapAreSummarised() {
        let text = table(rows: 125).renderCompact()
        let rowLines = text.split(separator: "\n").filter { $0.contains(" AXRow: ") }
        XCTAssertEqual(rowLines.count, UITree.maxRowsPerContainer)
        XCTAssertTrue(text.contains("… 65 more rows not shown"))
        XCTAssertTrue(text.contains("mac_click"))
    }

    func testRowWithControlIsRenderedInFull() {
        let button = UINode(ref: "e99", role: "AXCheckBox", title: "Select", identifier: nil, value: "0",
                            frame: .init(x: 0, y: 0, width: 20, height: 20), isEnabled: true, actions: ["AXPress"], children: [])
        var row = fileRow(1, name: "a.png"); row.children.append(wrap("e98", "AXCell", [button]))
        let tree = UITree(generation: 1, bundleId: "app", root: wrap("e1", "AXGroup", [row]))
        let text = tree.renderCompact()
        XCTAssertTrue(text.contains("e20 AXRow [AXShowDefaultUI]"))
        XCTAssertTrue(text.contains("e99 AXCheckBox \"Select\""))
        XCTAssertTrue(text.contains("value=a.png"))
    }

    func testMenuBarCollapsesToTitlesUnlessAsked() {
        let item = UINode(ref: "e5", role: "AXMenuItem", title: "Save", identifier: nil, value: nil,
                          frame: .init(x: 0, y: 0, width: 100, height: 20), isEnabled: true, actions: ["AXPress"], children: [])
        let menu = UINode(ref: "e4", role: "AXMenu", title: nil, identifier: nil, value: nil,
                          frame: .init(x: 0, y: 0, width: 100, height: 200), isEnabled: true, actions: [], children: [item])
        let file = UINode(ref: "e3", role: "AXMenuBarItem", title: "File", identifier: nil, value: nil,
                          frame: .init(x: 0, y: 0, width: 40, height: 20), isEnabled: true, actions: ["AXPress"], children: [menu])
        let edit = UINode(ref: "e6", role: "AXMenuBarItem", title: "Edit", identifier: nil, value: nil,
                          frame: .init(x: 40, y: 0, width: 40, height: 20), isEnabled: true, actions: ["AXPress"], children: [])
        let bar = UINode(ref: "e2", role: "AXMenuBar", title: nil, identifier: nil, value: nil,
                         frame: .init(x: 0, y: 0, width: 800, height: 20), isEnabled: true, actions: [], children: [file, edit])
        let tree = UITree(generation: 1, bundleId: "app", root: wrap("e1", "AXGroup", [bar]))
        let collapsed = tree.renderCompact()
        XCTAssertTrue(collapsed.contains("e2 AXMenuBar: File | Edit"), collapsed)
        XCTAssertFalse(collapsed.contains("Save"))
        XCTAssertTrue(collapsed.contains("include_menus"))
        let expanded = tree.renderCompact(includeMenus: true)
        XCTAssertTrue(expanded.contains(#"e5 AXMenuItem "Save""#))
    }

    func testLongValuesAreClipped() {
        let long = String(repeating: "x", count: 1000)
        let tree = UITree(generation: 1, bundleId: "app", root: wrap("e1", "AXGroup", [text("e2", long)]))
        let line = tree.renderCompact().split(separator: "\n").last!
        XCTAssertTrue(line.contains("… (+800 chars)"), String(line))
        XCTAssertLessThan(line.count, 260)
    }

    func testRenderMatchesFindsRowsAndControlsWithWindow() {
        let button = UINode(ref: "e9", role: "AXButton", title: "Sound Effects", identifier: nil, value: nil,
                            frame: .init(x: 0, y: 0, width: 80, height: 24), isEnabled: true, actions: ["AXPress"], children: [])
        var t = table(rows: 3)
        let win = UINode(ref: "e0", role: "AXWindow", title: "Settings", identifier: nil, value: nil,
                         frame: .init(x: 0, y: 0, width: 800, height: 600), isEnabled: true, actions: [], children: [t.root, button])
        t.root = win
        let text = t.renderMatches("file2")
        XCTAssertTrue(text.contains("[Settings] e40 AXRow: file2.png"), text)
        XCTAssertFalse(text.contains("file1.png"))
        XCTAssertTrue(t.renderMatches("sound").contains("e9 AXButton \"Sound Effects\""))
        XCTAssertTrue(t.renderMatches("zzz").contains("nothing matches"))
    }

    func testAnonymousWrapperSpendsNoLineButKeepsChildren() {
        let tree = UITree(generation: 1, bundleId: "app",
                          root: wrap("e1", "AXGroup", [wrap("e2", "AXGroup", [text("e3", "Hello")])]))
        let text = tree.renderCompact()
        XCTAssertFalse(text.contains("e1 AXGroup"))
        XCTAssertFalse(text.contains("e2 AXGroup"))
        XCTAssertTrue(text.contains("e3 AXStaticText value=Hello"))
        XCTAssertTrue(text.split(separator: "\n")[1].hasPrefix("e3"), "hoisted child keeps the parent's depth")
    }
}

#endif
