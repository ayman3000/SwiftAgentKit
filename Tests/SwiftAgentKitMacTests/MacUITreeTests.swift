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
}
#endif
