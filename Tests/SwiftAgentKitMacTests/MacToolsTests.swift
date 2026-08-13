import XCTest
@testable import SwiftAgentKitMac
import SwiftAgentKit

#if os(macOS)
final class MockAX: AXDriving, @unchecked Sendable {
    var trusted = true
    var lastCall = ""
    var tree = UITree(generation: 1, bundleId: "com.apple.TextEdit",
        root: UINode(ref: "e1", role: "AXWindow", title: "Untitled", identifier: nil, value: nil,
                     frame: .init(x: 0, y: 0, width: 800, height: 600),
                     isEnabled: true, actions: [], children: []))
    var errorToThrow: Error?
    func isTrusted() -> Bool { trusted }
    func snapshot(bundleId: String) async throws -> UITree { lastCall = "snapshot:\(bundleId)"; if let e = errorToThrow { throw e }; return tree }
    func click(bundleId: String, target: MacTarget) async throws { lastCall = "click:\(target.ref ?? target.title ?? "?")"; if let e = errorToThrow { throw e } }
    func type(bundleId: String, text: String, target: MacTarget?) async throws { lastCall = "type:\(text)"; if let e = errorToThrow { throw e } }
    func key(bundleId: String, keys: String) async throws { lastCall = "key:\(keys)"; if let e = errorToThrow { throw e } }
    func waitFor(bundleId: String, target: MacTarget, timeoutSeconds: Double, forDisappearance: Bool) async throws -> UITree { lastCall = "wait"; if let e = errorToThrow { throw e }; return tree }
    func launch(bundleId: String) async throws { lastCall = "launch:\(bundleId)"; if let e = errorToThrow { throw e } }
    func runningApps() -> [(name: String, bundleId: String)] { [("TextEdit","com.apple.TextEdit"), ("Mail","com.apple.mail")] }
}

final class MacToolsTests: XCTestCase {
    let allow: @Sendable () -> Set<String> = { ["com.apple.TextEdit"] }

    func testMacUIRendersTreeForAllowedApp() async throws {
        let mock = MockAX()
        let r = try await MacUITool(client: mock, allowlistProvider: allow)
            .execute(parameters: ["bundle_id": "com.apple.TextEdit"])
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.result.contains("generation 1"))
        XCTAssertEqual(mock.lastCall, "snapshot:com.apple.TextEdit")
    }

    func testMacUIDeniesDisallowedApp() async throws {
        let mock = MockAX()
        let r = try await MacUITool(client: mock, allowlistProvider: allow)
            .execute(parameters: ["bundle_id": "com.apple.mail"])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.result.contains("not permitted"))
        XCTAssertEqual(mock.lastCall, "", "must NOT touch AX for a disallowed app")
    }

    func testNotTrustedShortCircuits() async throws {
        let mock = MockAX(); mock.trusted = false
        let r = try await MacUITool(client: mock, allowlistProvider: allow)
            .execute(parameters: ["bundle_id": "com.apple.TextEdit"])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.result.contains("Accessibility"))
        XCTAssertEqual(mock.lastCall, "")
    }

    func testMacClickByRefPassesTarget() async throws {
        let mock = MockAX()
        _ = try await MacClickTool(client: mock, allowlistProvider: allow)
            .execute(parameters: ["bundle_id": "com.apple.TextEdit", "ref": "e2", "generation": 1])
        XCTAssertEqual(mock.lastCall, "click:e2")
    }

    func testMacClickRequiresConfirmation() {
        XCTAssertTrue(MacClickTool(client: MockAX(), allowlistProvider: allow).requiresConfirmation)
        XCTAssertTrue(MacTypeTool(client: MockAX(), allowlistProvider: allow).requiresConfirmation)
        XCTAssertTrue(MacKeyTool(client: MockAX(), allowlistProvider: allow).requiresConfirmation)
        XCTAssertTrue(MacLaunchTool(client: MockAX(), allowlistProvider: allow).requiresConfirmation)
    }

    func testReadToolsDoNotRequireConfirmation() {
        XCTAssertFalse(MacUITool(client: MockAX(), allowlistProvider: allow).requiresConfirmation)
        XCTAssertFalse(MacAppsTool(client: MockAX(), allowlistProvider: allow).requiresConfirmation)
        XCTAssertFalse(MacWaitTool(client: MockAX(), allowlistProvider: allow).requiresConfirmation)
    }

    func testMacAppsListsOnlyAllowlisted() async throws {
        let mock = MockAX()
        let r = try await MacAppsTool(client: mock, allowlistProvider: allow).execute(parameters: [:])
        XCTAssertTrue(r.result.contains("com.apple.TextEdit"))
        XCTAssertFalse(r.result.contains("com.apple.mail"))
    }

    func testMacAppsWorksWithoutAX() async throws {
        let mock = MockAX(); mock.trusted = false
        let r = try await MacAppsTool(client: mock, allowlistProvider: allow).execute(parameters: [:])
        XCTAssertFalse(r.isError, "mac_apps should work without AX permission")
        XCTAssertTrue(r.result.contains("com.apple.TextEdit"))
    }

    func testWaitTimeoutReturnsCurrentTree() async throws {
        let mock = MockAX()
        mock.errorToThrow = MacDriverError(code: "timeout", message: "not met", tree: mock.tree)
        let r = try await MacWaitTool(client: mock, allowlistProvider: allow)
            .execute(parameters: ["bundle_id": "com.apple.TextEdit", "title": "Done", "timeout_seconds": 1.0])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.result.contains("generation 1"))
    }

    func testMakeMacToolsReturnsSeven() {
        let tools = makeMacTools(allowlistProvider: allow, client: MockAX())
        XCTAssertEqual(tools.count, 7)
        XCTAssertEqual(Set(tools.map(\.name)),
            ["mac_apps","mac_ui","mac_click","mac_type","mac_key","mac_wait","mac_launch"])
    }
}
#endif
