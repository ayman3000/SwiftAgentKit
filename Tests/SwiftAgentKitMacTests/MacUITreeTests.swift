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
}
