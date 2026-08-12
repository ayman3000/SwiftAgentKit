import XCTest
@testable import SwiftAgentKitSimulator

final class SimWireTests: XCTestCase {
    private func sampleTree() -> UITree {
        let save = UINode(ref: "e2", type: "Button", label: "Save", identifier: "save_btn",
                          value: nil, frame: .init(x: 10, y: 100, width: 80, height: 44),
                          isHittable: true, isEnabled: true, children: [])
        let hidden = UINode(ref: "e3", type: "Other", label: nil, identifier: nil,
                            value: nil, frame: .init(x: 0, y: 0, width: 0, height: 0), isHittable: false, isEnabled: true, children: [])
        let root = UINode(ref: "e1", type: "Window", label: nil, identifier: nil,
                          value: nil, frame: .init(x: 0, y: 0, width: 390, height: 844),
                          isHittable: false, isEnabled: true, children: [save, hidden])
        return UITree(generation: 7, bundleId: "com.example.app", root: root)
    }

    func testRoundTripsThroughJSON() throws {
        let tree = sampleTree()
        let data = try JSONEncoder().encode(tree)
        let back = try JSONDecoder().decode(UITree.self, from: data)
        XCTAssertEqual(back, tree)
    }

    func testRenderCompactShowsRefTypeLabelAndSkipsEmptyLeaves() {
        let text = sampleTree().renderCompact()
        XCTAssertTrue(text.contains(#"e2 Button "Save" id=save_btn"#))
        XCTAssertTrue(text.contains("generation 7"))
        XCTAssertFalse(text.contains("e3"), "anonymous zero-size leaf must be pruned from render")
    }

    func testRenderCompactIndentsChildren() {
        let lines = sampleTree().renderCompact().split(separator: "\n")
        let saveLine = lines.first { $0.contains("e2") }!
        XCTAssertTrue(saveLine.hasPrefix("  "), "children indent under root")
    }
}
