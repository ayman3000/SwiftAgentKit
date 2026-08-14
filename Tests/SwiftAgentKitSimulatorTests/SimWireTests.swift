import XCTest
@testable import SwiftAgentKitSimulator

final class SimWireTests: XCTestCase {
    private func sampleTree() -> UITree {
        let save = UINode(ref: "e2", type: "Button", label: "Save", identifier: "save_btn",
                          value: nil, frame: .init(x: 10, y: 100, width: 80, height: 44),
                          isHittable: true, isEnabled: true, children: [])
        let hidden = UINode(ref: "e3", type: "Other", label: nil, identifier: nil,
                            value: nil, frame: .zero, isHittable: false, isEnabled: true, children: [])
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

extension SimWireTests {
    private func node(ref: String = "e1", type: String, label: String? = nil,
                      identifier: String? = nil, value: String? = nil,
                      hittable: Bool = false, children: [UINode] = []) -> UINode {
        UINode(ref: ref, type: type, label: label, identifier: identifier, value: value,
               frame: .init(x: 0, y: 0, width: 10, height: 10),
               isHittable: hittable, isEnabled: true, children: children)
    }

    func testTypeNameMapsKnownRawValues() {
        XCTAssertEqual(node(type: "XCUIElementType(rawValue: 9)").typeName, "Button")
        XCTAssertEqual(node(type: "XCUIElementType(rawValue: 48)").typeName, "StaticText")
        XCTAssertEqual(node(type: "XCUIElementType(rawValue: 43)").typeName, "Image")
        XCTAssertEqual(node(type: "XCUIElementType(rawValue: 49)").typeName, "TextField")
    }

    func testTypeNameFallsBackForUnknown() {
        XCTAssertEqual(node(type: "XCUIElementType(rawValue: 9999)").typeName,
                       "XCUIElementType(rawValue: 9999)")
        XCTAssertEqual(node(type: "Weird").typeName, "Weird")
    }

    /// root Window(4) [ Other(1,hittable) [ Other(1,hittable) [ StaticText(48)"Gold Prices",
    /// Button(9) id=dollarsign.circle.fill ] ], Button(9,hittable,no id/label,no children) ]
    private func slimFixture() -> UITree {
        let title = node(ref: "e4", type: "XCUIElementType(rawValue: 48)", label: "Gold Prices", hittable: true)
        let dollar = node(ref: "e5", type: "XCUIElementType(rawValue: 9)",
                          identifier: "dollarsign.circle.fill", hittable: true)
        let inner = node(ref: "e3", type: "XCUIElementType(rawValue: 1)", hittable: true, children: [title, dollar])
        let container = node(ref: "e2", type: "XCUIElementType(rawValue: 1)", hittable: true, children: [inner])
        let bareLeaf = node(ref: "e6", type: "XCUIElementType(rawValue: 9)", hittable: true)
        let root = node(ref: "e1", type: "XCUIElementType(rawValue: 4)", hittable: false,
                        children: [container, bareLeaf])
        return UITree(generation: 1, bundleId: "com.x", root: root)
    }

    func testRenderSlimKeepsContentAndInteractiveLeaves() {
        let out = slimFixture().renderSlim()
        XCTAssertTrue(out.contains("Gold Prices"))
        XCTAssertTrue(out.contains("dollarsign.circle.fill"))
        XCTAssertTrue(out.contains("e6 Button"), "bare hittable leaf kept for its ref")
    }

    func testRenderSlimFlattensStructuralContainers() {
        let out = slimFixture().renderSlim()
        XCTAssertFalse(out.contains("e2 "), "structural container flattened")
        XCTAssertFalse(out.contains("e3 "), "structural container flattened")
        XCTAssertFalse(out.contains("e1 "), "unlabeled non-hittable root flattened")
    }

    func testRenderSlimUsesFriendlyTypeNames() {
        let out = slimFixture().renderSlim()
        XCTAssertTrue(out.contains("StaticText"))
        XCTAssertTrue(out.contains("Button"))
        XCTAssertFalse(out.contains("rawValue"), "slim never shows raw type strings for known types")
    }

    func testRenderSlimHasGenerationHeader() {
        XCTAssertTrue(slimFixture().renderSlim().hasPrefix("UI of com.x — generation 1\n"))
    }

    func testRenderCompactUnchangedStillShowsStructuralNodes() {
        // renderCompact keeps hittable/frame>0 nodes (regression guard for full:true).
        let out = slimFixture().renderCompact()
        XCTAssertTrue(out.contains("e2"))
        XCTAssertTrue(out.contains("e3"))
    }
}
