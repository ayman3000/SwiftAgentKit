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

    private func slimVsFullTree() -> UITree {
        let text = UINode(ref: "e3", type: "XCUIElementType(rawValue: 48)", label: "Hi",
                          identifier: nil, value: nil, frame: .init(x: 0, y: 0, width: 5, height: 5),
                          isHittable: true, isEnabled: true, children: [])
        let container = UINode(ref: "e2", type: "XCUIElementType(rawValue: 1)", label: nil,
                               identifier: nil, value: nil, frame: .init(x: 0, y: 0, width: 100, height: 100),
                               isHittable: false, isEnabled: true, children: [text])
        let root = UINode(ref: "e1", type: "XCUIElementType(rawValue: 4)", label: nil,
                          identifier: nil, value: nil, frame: .init(x: 0, y: 0, width: 390, height: 844),
                          isHittable: false, isEnabled: true, children: [container])
        return UITree(generation: 1, bundleId: "com.x", root: root)
    }

    func testSimUIDefaultSlimsTree() async throws {
        let mock = MockDriver(); mock.treeToReturn = slimVsFullTree()
        let tool = SimUITool(client: mock, session: makeSession())
        let r = try await tool.execute(parameters: [:])
        XCTAssertTrue(r.result.contains("Hi"))
        XCTAssertFalse(r.result.contains("e2 "), "structural node flattened by default")
    }

    func testSimUIFullReturnsCompactTree() async throws {
        let mock = MockDriver(); mock.treeToReturn = slimVsFullTree()
        let tool = SimUITool(client: mock, session: makeSession())
        let r = try await tool.execute(parameters: ["full": true])
        XCTAssertTrue(r.result.contains("e2 "), "full:true returns the complete tree")
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

    // MARK: SimBootTool.resolveDevice

    func makeDevice(name: String, udid: String = UUID().uuidString) -> Simctl.SimDevice {
        Simctl.SimDevice(udid: udid, name: name, state: "Shutdown", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-17-0")
    }

    func testResolveDeviceExactMatch() {
        let devices = [makeDevice(name: "iPhone 15 Pro"), makeDevice(name: "iPhone 15 Pro Max")]
        let result = SimBootTool.resolveDevice(name: "iPhone 15 Pro", in: devices)
        guard case .found(let dev) = result else { return XCTFail("Expected found") }
        XCTAssertEqual(dev.name, "iPhone 15 Pro", "Exact match should beat substring")
    }

    func testResolveDeviceExactMatchCaseInsensitive() {
        let devices = [makeDevice(name: "iPhone 15 Pro"), makeDevice(name: "iPad Pro")]
        let result = SimBootTool.resolveDevice(name: "iphone 15 pro", in: devices)
        guard case .found(let dev) = result else { return XCTFail("Expected found") }
        XCTAssertEqual(dev.name, "iPhone 15 Pro")
    }

    func testResolveDeviceUniqueSubstringMatch() {
        let devices = [makeDevice(name: "iPhone 16"), makeDevice(name: "iPad Air")]
        let result = SimBootTool.resolveDevice(name: "iPad", in: devices)
        guard case .found(let dev) = result else { return XCTFail("Expected found") }
        XCTAssertEqual(dev.name, "iPad Air")
    }

    func testResolveDeviceAmbiguousSubstringReturnsError() {
        let devices = [makeDevice(name: "iPhone 15 Pro"), makeDevice(name: "iPhone 15 Pro Max")]
        // Neither is an exact match for "iPhone 15"; both contain it as substring
        let result = SimBootTool.resolveDevice(name: "iPhone 15", in: devices)
        guard case .notFound(let msg) = result else { return XCTFail("Expected notFound for ambiguous match") }
        XCTAssertTrue(msg.contains("matches multiple simulators"), "Error should list candidates; got: \(msg)")
        XCTAssertTrue(msg.contains("iPhone 15 Pro"), "Error should name the ambiguous candidates")
    }

    func testResolveDeviceNoMatchReturnsError() {
        let devices = [makeDevice(name: "iPhone 15 Pro")]
        let result = SimBootTool.resolveDevice(name: "iPad Air", in: devices)
        guard case .notFound(let msg) = result else { return XCTFail("Expected notFound") }
        XCTAssertTrue(msg.contains("No simulator found"), "Should say not found; got: \(msg)")
    }

    func testResolveDeviceExactBeatsTwoSubstringMatches() {
        // "iPhone 15 Pro" is an exact match; "iPhone 15 Pro Max" would also contain "iPhone 15 Pro"
        // Exact match should win without ambiguity error
        let devices = [makeDevice(name: "iPhone 15 Pro"), makeDevice(name: "iPhone 15 Pro Max")]
        let result = SimBootTool.resolveDevice(name: "iPhone 15 Pro", in: devices)
        guard case .found(let dev) = result else { return XCTFail("Expected found; exact match must win") }
        XCTAssertEqual(dev.name, "iPhone 15 Pro")
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

    func testMakeSimulatorToolsReturns14Tools() {
        let mock = MockDriver()
        let session = SimSession()
        let tools = makeSimulatorTools(session: session, client: mock)
        XCTAssertEqual(tools.count, 14)
    }

    func testMakeSimulatorToolsHasExpectedNames() {
        let mock = MockDriver()
        let session = SimSession()
        let tools = makeSimulatorTools(session: session, client: mock)
        let names = Set(tools.map { $0.name })
        let expected: Set<String> = ["sim_list", "sim_boot", "sim_launch", "sim_terminate",
                                     "sim_ui", "sim_tap", "sim_type", "sim_swipe",
                                     "sim_press", "sim_wait", "sim_alert", "sim_screenshot",
                                     "sim_build_install", "sim_logs"]
        XCTAssertEqual(names, expected)
    }

    // MARK: - SimBuildInstallTool tests

    func testBuildInstallRequiresBootedDevice() async throws {
        let session = SimSession()   // udid is nil
        let tool = SimBuildInstallTool(session: session)
        let result = try await tool.execute(parameters: [
            "project_path": "/tmp/Test.xcodeproj",
            "scheme": "MyScheme",
        ])
        XCTAssertTrue(result.isError, "Should return error when no device is booted")
        XCTAssertTrue(result.result.contains("sim_boot"),
            "Error should mention sim_boot; got: \(result.result)")
    }

    func testBuildInstallRequiresConfirmation() {
        let session = SimSession()
        let tool = SimBuildInstallTool(session: session)
        XCTAssertTrue(tool.requiresConfirmation)
    }

    func testFindNewestApp() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("newestApp-\(UUID().uuidString)")
        let simDir = base.appendingPathComponent("iPhone-iphonesimulator")
        try fm.createDirectory(at: simDir, withIntermediateDirectories: true)

        // Create A.app (older)
        let aApp = simDir.appendingPathComponent("A.app")
        try fm.createDirectory(at: aApp, withIntermediateDirectories: true)
        let oldDate = Date(timeIntervalSinceNow: -3600)
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: aApp.path)

        // Create B.app (newer)
        let bApp = simDir.appendingPathComponent("B.app")
        try fm.createDirectory(at: bApp, withIntermediateDirectories: true)
        let newDate = Date(timeIntervalSinceNow: -60)
        try fm.setAttributes([.modificationDate: newDate], ofItemAtPath: bApp.path)

        defer { try? fm.removeItem(at: base) }

        let result = SimBuildInstallTool.newestApp(in: base.path)
        XCTAssertNotNil(result, "newestApp should find an app")
        XCTAssertEqual(result?.lastPathComponent, "B.app",
            "Should pick the newer B.app; got \(result?.lastPathComponent ?? "nil")")
    }

    func testFindNewestAppReturnsNilForEmptyDir() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("newestApp-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let result = SimBuildInstallTool.newestApp(in: base.path)
        XCTAssertNil(result, "Should return nil when no .app bundles are found")
    }

    // MARK: - SimLogsTool tests

    func testLogsRequiresBootedDevice() async throws {
        let session = SimSession()   // udid is nil
        let tool = SimLogsTool(session: session)
        let result = try await tool.execute(parameters: [:])
        XCTAssertTrue(result.isError, "Should return error when no device is booted")
        XCTAssertTrue(result.result.contains("sim_boot"),
            "Error should mention sim_boot; got: \(result.result)")
    }

    func testLogsDoesNotRequireConfirmation() {
        let session = SimSession()
        let tool = SimLogsTool(session: session)
        XCTAssertFalse(tool.requiresConfirmation)
    }

    func testLogsStopRequiresPid() async throws {
        let session = SimSession()
        session.udid = "FAKE-UDID"
        let tool = SimLogsTool(session: session)
        let result = try await tool.execute(parameters: ["stop": true])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.result.contains("pid"))
    }

    func testLogsRequiresActiveBundleId() async throws {
        let session = SimSession()
        session.udid = "FAKE-UDID"
        // No currentBundleId, no explicit bundle_id
        let tool = SimLogsTool(session: session)
        let result = try await tool.execute(parameters: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.result.contains("bundle_id") || result.result.contains("sim_launch"))
    }
}
#endif
