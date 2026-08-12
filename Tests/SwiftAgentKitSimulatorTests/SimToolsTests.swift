import XCTest
@testable import SwiftAgentKitSimulator
import SwiftAgentKit

#if os(macOS)
final class MockDriver: SimDriving, @unchecked Sendable {
    var lastCall: String = ""
    var treeToReturn = UITree(generation: 1, bundleId: "com.x",
        root: UINode(ref: "e1", type: "Window", label: nil, identifier: nil, value: nil,
                     frame: .init(x: 0, y: 0, width: 390, height: 844),
                     isHittable: false, isEnabled: true, children: []))
    var errorToThrow: Error?

    func snapshot(bundleId: String) async throws -> UITree {
        lastCall = "snapshot:\(bundleId)"
        if let e = errorToThrow { throw e }
        return treeToReturn
    }

    func tap(bundleId: String, target: SimWire.Target, longPress: Bool) async throws {
        lastCall = "tap:\(target.ref ?? target.label ?? "?")"
        if let e = errorToThrow { throw e }
    }

    func type(bundleId: String, text: String, target: SimWire.Target?) async throws {
        lastCall = "type:\(text)"
        if let e = errorToThrow { throw e }
    }

    func swipe(bundleId: String, direction: String, target: SimWire.Target?) async throws {
        lastCall = "swipe:\(direction)"
        if let e = errorToThrow { throw e }
    }

    func pressHome() async throws {
        lastCall = "pressHome"
        if let e = errorToThrow { throw e }
    }

    func waitFor(bundleId: String, target: SimWire.Target, timeoutSeconds: Double,
                 forDisappearance: Bool) async throws -> UITree {
        lastCall = "waitFor:\(target.label ?? target.identifier ?? "?")"
        if let e = errorToThrow { throw e }
        return treeToReturn
    }

    func alert(accept: Bool) async throws {
        lastCall = "alert:\(accept)"
        if let e = errorToThrow { throw e }
    }

    func launch(bundleId: String, terminateFirst: Bool) async throws {
        lastCall = "launch:\(bundleId)"
        if let e = errorToThrow { throw e }
    }

    func terminate(bundleId: String) async throws {
        lastCall = "terminate:\(bundleId)"
        if let e = errorToThrow { throw e }
    }

    func screenshot() async throws -> Data {
        lastCall = "screenshot"
        if let e = errorToThrow { throw e }
        return Data([0x89, 0x50])
    }
}

final class SimToolsTests: XCTestCase {

    func makeSession() -> SimSession {
        let s = SimSession()
        s.currentBundleId = "com.x"
        return s
    }

    // MARK: sim_ui

    func testSimUIRendersTree() async throws {
        let mock = MockDriver()
        let tool = SimUITool(client: mock, session: makeSession())
        let result = try await tool.execute(parameters: [:])
        XCTAssertTrue(result.result.contains("generation 1"))
        XCTAssertEqual(mock.lastCall, "snapshot:com.x")
    }

    func testSimUIUsesExplicitBundleId() async throws {
        let mock = MockDriver()
        let tool = SimUITool(client: mock, session: makeSession())
        _ = try await tool.execute(parameters: ["bundle_id": "com.other"])
        XCTAssertEqual(mock.lastCall, "snapshot:com.other")
    }

    // MARK: sim_tap

    func testSimTapByRefPassesGeneration() async throws {
        let mock = MockDriver()
        let tool = SimTapTool(client: mock, session: makeSession())
        _ = try await tool.execute(parameters: ["ref": "e5", "generation": 3])
        XCTAssertEqual(mock.lastCall, "tap:e5")
    }

    func testSimTapByLabel() async throws {
        let mock = MockDriver()
        let tool = SimTapTool(client: mock, session: makeSession())
        _ = try await tool.execute(parameters: ["label": "Submit"])
        XCTAssertEqual(mock.lastCall, "tap:Submit")
    }

    func testSimTapDriverErrorIncludesTree() async throws {
        let mock = MockDriver()
        mock.errorToThrow = SimDriverError(code: "not_found", message: "element not found",
                                           tree: mock.treeToReturn)
        let tool = SimTapTool(client: mock, session: makeSession())
        let result = try await tool.execute(parameters: ["label": "Missing"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.result.contains("generation 1"), "error result must embed current UI tree")
    }

    // MARK: sim_type

    func testSimTypeRecordsText() async throws {
        let mock = MockDriver()
        let tool = SimTypeTool(client: mock, session: makeSession())
        _ = try await tool.execute(parameters: ["text": "hello"])
        XCTAssertEqual(mock.lastCall, "type:hello")
    }

    func testSimTypeMissingTextReturnsError() async throws {
        let mock = MockDriver()
        let tool = SimTypeTool(client: mock, session: makeSession())
        let result = try await tool.execute(parameters: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.result.contains("text"))
    }

    // MARK: sim_swipe

    func testSimSwipeDirection() async throws {
        let mock = MockDriver()
        let tool = SimSwipeTool(client: mock, session: makeSession())
        _ = try await tool.execute(parameters: ["direction": "up"])
        XCTAssertEqual(mock.lastCall, "swipe:up")
    }

    // MARK: sim_press

    func testSimPressHome() async throws {
        let mock = MockDriver()
        let tool = SimPressTool(client: mock, session: makeSession())
        _ = try await tool.execute(parameters: ["button": "home"])
        XCTAssertEqual(mock.lastCall, "pressHome")
    }

    // MARK: sim_wait

    func testWaitTimeoutReturnsCurrentTreeInErrorResult() async throws {
        let mock = MockDriver()
        mock.errorToThrow = SimDriverError(code: "timeout", message: "not met",
                                           tree: mock.treeToReturn)
        let tool = SimWaitTool(client: mock, session: makeSession())
        let result = try await tool.execute(parameters: ["label": "Done", "timeout_seconds": 1.0])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.result.contains("generation 1"), "error must include current UI so the model sees state")
    }

    func testWaitSuccessRendersTree() async throws {
        let mock = MockDriver()
        let tool = SimWaitTool(client: mock, session: makeSession())
        let result = try await tool.execute(parameters: ["label": "Done"])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.result.contains("generation 1"))
    }

    // MARK: sim_alert

    func testSimAlertAccept() async throws {
        let mock = MockDriver()
        let tool = SimAlertTool(client: mock, session: makeSession())
        _ = try await tool.execute(parameters: ["accept": true])
        XCTAssertEqual(mock.lastCall, "alert:true")
    }

    func testSimAlertDismiss() async throws {
        let mock = MockDriver()
        let tool = SimAlertTool(client: mock, session: makeSession())
        _ = try await tool.execute(parameters: ["accept": false])
        XCTAssertEqual(mock.lastCall, "alert:false")
    }

    // MARK: sim_screenshot

    func testScreenshotReturnsImage() async throws {
        let mock = MockDriver()
        let tool = SimScreenshotTool(client: mock, session: makeSession())
        let result = try await tool.execute(parameters: [:])
        XCTAssertEqual(result.images.count, 1)
    }

    func testScreenshotIsNotError() async throws {
        let mock = MockDriver()
        let tool = SimScreenshotTool(client: mock, session: makeSession())
        let result = try await tool.execute(parameters: [:])
        XCTAssertFalse(result.isError)
    }

    // MARK: Missing bundle ID

    func testMissingBundleIdIsClearError() async throws {
        let mock = MockDriver()
        let tool = SimUITool(client: mock, session: SimSession())   // no current app
        let result = try await tool.execute(parameters: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.result.contains("sim_launch"))
    }

    func testMissingBundleIdOnTapTool() async throws {
        let mock = MockDriver()
        let tool = SimTapTool(client: mock, session: SimSession())
        let result = try await tool.execute(parameters: ["label": "Button"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.result.contains("sim_launch"))
    }

    // MARK: sim_launch

    func testSimLaunchSetsSessionBundleId() async throws {
        let mock = MockDriver()
        let session = SimSession()
        let tool = SimLaunchTool(client: mock, session: session)
        _ = try await tool.execute(parameters: ["bundle_id": "com.example.app"])
        XCTAssertEqual(session.currentBundleId, "com.example.app")
        XCTAssertEqual(mock.lastCall, "launch:com.example.app")
    }

    func testSimLaunchMissingBundleIdReturnsError() async throws {
        let mock = MockDriver()
        let tool = SimLaunchTool(client: mock, session: SimSession())
        let result = try await tool.execute(parameters: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.result.contains("bundle_id"))
    }

    // MARK: sim_terminate

    func testSimTerminateClearsSessionBundleId() async throws {
        let mock = MockDriver()
        let session = makeSession()   // currentBundleId = "com.x"
        let tool = SimTerminateTool(client: mock, session: session)
        _ = try await tool.execute(parameters: [:])
        XCTAssertNil(session.currentBundleId)
        XCTAssertEqual(mock.lastCall, "terminate:com.x")
    }

    func testSimTerminateOtherAppDoesNotClearSession() async throws {
        let mock = MockDriver()
        let session = makeSession()   // currentBundleId = "com.x"
        let tool = SimTerminateTool(client: mock, session: session)
        _ = try await tool.execute(parameters: ["bundle_id": "com.other"])
        XCTAssertEqual(session.currentBundleId, "com.x", "should not clear session for a different bundle")
    }

    // MARK: requiresConfirmation

    func testLifecycleToolsRequireConfirmation() {
        let mock = MockDriver()
        let session = SimSession()
        XCTAssertTrue(SimBootTool(session: session).requiresConfirmation)
        XCTAssertTrue(SimLaunchTool(client: mock, session: session).requiresConfirmation)
        XCTAssertTrue(SimTerminateTool(client: mock, session: session).requiresConfirmation)
    }

    func testUIToolsDoNotRequireConfirmation() {
        let mock = MockDriver()
        let session = SimSession()
        XCTAssertFalse(SimUITool(client: mock, session: session).requiresConfirmation)
        XCTAssertFalse(SimTapTool(client: mock, session: session).requiresConfirmation)
        XCTAssertFalse(SimListTool().requiresConfirmation)
    }

    // MARK: makeSimulatorTools

    func testMakeSimulatorToolsReturns12Tools() {
        let mock = MockDriver()
        let session = SimSession()
        let tools = makeSimulatorTools(session: session, client: mock)
        XCTAssertEqual(tools.count, 12)
    }

    func testMakeSimulatorToolsHasExpectedNames() {
        let mock = MockDriver()
        let session = SimSession()
        let tools = makeSimulatorTools(session: session, client: mock)
        let names = Set(tools.map { $0.name })
        let expected: Set<String> = ["sim_list", "sim_boot", "sim_launch", "sim_terminate",
                                     "sim_ui", "sim_tap", "sim_type", "sim_swipe",
                                     "sim_press", "sim_wait", "sim_alert", "sim_screenshot"]
        XCTAssertEqual(names, expected)
    }
}
#endif
