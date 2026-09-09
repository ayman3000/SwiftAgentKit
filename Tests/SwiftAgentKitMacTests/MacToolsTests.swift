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
    func click(bundleId: String, target: MacTarget, options: MacClickOptions) async throws -> String { lastCall = "click:\(target.ref ?? target.title ?? "?"):\(options.clicks)\(options.rightButton ? "R" : "")"; if let e = errorToThrow { throw e }; return "Pressed." }
    func type(bundleId: String, text: String, target: MacTarget?, replace: Bool) async throws -> Bool { lastCall = "type:\(text)\(replace ? ":replace" : "")"; if let e = errorToThrow { throw e }; return true }
    func key(bundleId: String, keys: String) async throws { lastCall = "key:\(keys)"; if let e = errorToThrow { throw e } }
    func scroll(bundleId: String, target: MacTarget?, direction: String, amount: Int) async throws { lastCall = "scroll:\(direction):\(amount)"; if let e = errorToThrow { throw e } }
    func choose(bundleId: String, target: MacTarget, item: String) async throws -> String { lastCall = "choose:\(target.title ?? target.ref ?? "?"):\(item)"; if let e = errorToThrow { throw e }; return "Chose '\(item)'." }
    func waitFor(bundleId: String, target: MacTarget, timeoutSeconds: Double, forDisappearance: Bool) async throws -> UITree { lastCall = "wait"; if let e = errorToThrow { throw e }; return tree }
    func launch(bundleId: String) async throws { lastCall = "launch:\(bundleId)"; if let e = errorToThrow { throw e } }
    func runningApps() -> [(name: String, bundleId: String)] { [("TextEdit","com.apple.TextEdit"), ("Mail","com.apple.mail")] }
    func screenshot(bundleId: String) async throws -> Data { lastCall = "screenshot:\(bundleId)"; if let e = errorToThrow { throw e }; return Data([0x89, 0x50, 0x4E, 0x47]) }
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
        XCTAssertEqual(mock.lastCall, "click:e2:1")
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

    func testMacAppsSeparatesAllowedFromRequestable() async throws {
        let mock = MockAX()
        let r = try await MacAppsTool(client: mock, allowlistProvider: allow).execute(parameters: [:])
        let allowedPart = r.result.components(separatedBy: "not yet allowed")[0]
        XCTAssertTrue(allowedPart.contains("com.apple.TextEdit"))
        XCTAssertFalse(allowedPart.contains("com.apple.mail"))
        // A running app outside the allowlist is listed as requestable, with the how-to.
        XCTAssertTrue(r.result.contains("not yet allowed"))
        XCTAssertTrue(r.result.contains("com.apple.mail"))
        XCTAssertTrue(r.result.contains("autonomous mode"))
    }

    func testTypedTextVerificationIsLineBased() {
        XCTAssertTrue(AXClient.contains("Hi Naseem\nBye", allLinesOf: "\nBye"))
        XCTAssertTrue(AXClient.contains("Hi Naseem\u{2029}Bye", allLinesOf: "Hi Naseem\nBye"))
        XCTAssertFalse(AXClient.contains("Hi Naseem\n", allLinesOf: "\nBye"), "a bare newline is not the text")
        XCTAssertTrue(AXClient.contains("anything", allLinesOf: "\n"), "only control characters: nothing to check")
        // Apps auto-capitalise and substitute smart punctuation.
        XCTAssertTrue(AXClient.contains("First line\nSecond line", allLinesOf: "first line\nsecond line"))
        XCTAssertTrue(AXClient.contains("Don\u{2019}t \u{201C}quote\u{201D} me \u{2014} ok", allLinesOf: "don't \"quote\" me - ok"))
    }

    func testClickPassesDoubleAndRightClickThrough() async throws {
        let mock = MockAX()
        let r = try await MacClickTool(client: mock, allowlistProvider: allow)
            .execute(parameters: ["bundle_id": "com.apple.TextEdit", "title": "Docs", "clicks": 2])
        XCTAssertEqual(mock.lastCall, "click:Docs:2")
        XCTAssertFalse(r.isError)
        _ = try await MacClickTool(client: mock, allowlistProvider: allow)
            .execute(parameters: ["bundle_id": "com.apple.TextEdit", "title": "Docs", "button": "right"])
        XCTAssertEqual(mock.lastCall, "click:Docs:1R")
    }

    func testTypeReplaceAndScrollReachTheDriver() async throws {
        let mock = MockAX()
        _ = try await MacTypeTool(client: mock, allowlistProvider: allow)
            .execute(parameters: ["bundle_id": "com.apple.TextEdit", "text": "x", "replace": true])
        XCTAssertEqual(mock.lastCall, "type:x:replace")
        let r = try await MacScrollTool(client: mock, allowlistProvider: allow)
            .execute(parameters: ["bundle_id": "com.apple.TextEdit", "direction": "down", "amount": 5])
        XCTAssertEqual(mock.lastCall, "scroll:down:5")
        XCTAssertTrue(r.result.contains("mac_ui"))
        XCTAssertEqual(makeMacTools(allowlistProvider: allow, client: mock).count, 9)
    }

    func testKeyComboAcceptsCommonSpellings() {
        XCTAssertEqual(parseKeyCombo("backspace")?.keyCode, parseKeyCombo("delete")?.keyCode)
        XCTAssertEqual(parseKeyCombo("Cmd + A")?.flags, .maskCommand)
        XCTAssertEqual(parseKeyCombo("arrowdown")?.keyCode, parseKeyCombo("down")?.keyCode)
        XCTAssertNotNil(parseKeyCombo("cmd+shift+z"))
        XCTAssertNil(parseKeyCombo("nosuchkey"))
    }

    func testEditableRolesCoverTextInputs() {
        for r in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"] {
            XCTAssertTrue(AXClient.editableRoles.contains(r), r)
        }
        XCTAssertFalse(AXClient.editableRoles.contains("AXButton"))
        XCTAssertFalse(AXClient.editableRoles.contains("AXStaticText"))
    }

    func testMacAppsWithNothingAllowedStillPointsAtRequesting() async throws {
        let mock = MockAX()
        let r = try await MacAppsTool(client: mock, allowlistProvider: { [] }).execute(parameters: [:])
        XCTAssertTrue(r.result.contains("No allowed apps are running yet"))
        XCTAssertTrue(r.result.contains("com.apple.TextEdit"))
        XCTAssertTrue(r.result.contains("mac_launch"))
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

    func testScreenshotToolIsOptInAndReturnsAnImage() async throws {
        let mock = MockAX()
        XCTAssertFalse(makeMacTools(allowlistProvider: allow, client: mock).contains { $0.name == "mac_screenshot" })
        let tools = makeMacTools(allowlistProvider: allow, client: mock, includeScreenshot: true)
        XCTAssertEqual(tools.count, 10)
        let r = try await MacScreenshotTool(client: mock, allowlistProvider: allow).execute(parameters: ["bundle_id": "com.apple.TextEdit"])
        XCTAssertFalse(r.isError); XCTAssertEqual(r.images.count, 1)
        let denied = try await MacScreenshotTool(client: mock, allowlistProvider: allow).execute(parameters: ["bundle_id": "com.apple.mail"])
        XCTAssertTrue(denied.isError)
    }

    func testMakeMacToolsReturnsAllNine() {
        let tools = makeMacTools(allowlistProvider: allow, client: MockAX())
        XCTAssertEqual(tools.count, 9)
        XCTAssertEqual(Set(tools.map(\.name)),
            ["mac_apps","mac_ui","mac_click","mac_type","mac_key","mac_wait","mac_launch","mac_scroll","mac_run"])
    }

    // MARK: - mac_run

    func testRunExecutesStepsInOrderAndReadsAfter() async throws {
        let mock = MockAX()
        let r = try await MacRunTool(client: mock, allowlistProvider: allow).execute(parameters: [
            "bundle_id": "com.apple.TextEdit",
            "steps": [["action": "key", "keys": "cmd+n"], ["action": "type", "text": "Hello"],
                      ["action": "click", "title": "Save"]],
        ])
        XCTAssertFalse(r.isError, r.result)
        XCTAssertTrue(r.result.contains("1. key cmd+n → sent"))
        XCTAssertTrue(r.result.contains("2. type \"Hello\" → typed, verified"))
        XCTAssertTrue(r.result.contains("3. click Save → Pressed."))
        XCTAssertTrue(r.result.contains("UI of com.apple.TextEdit"), "window read appended")
        XCTAssertEqual(mock.lastCall, "snapshot:com.apple.TextEdit", "read_after took the final snapshot")
        let quiet = try await MacRunTool(client: mock, allowlistProvider: allow).execute(parameters: [
            "bundle_id": "com.apple.TextEdit", "read_after": false,
            "steps": [["action": "double_click", "title": "Docs"]],
        ])
        XCTAssertEqual(mock.lastCall, "click:Docs:2")
        XCTAssertFalse(quiet.result.contains("UI of"))
    }

    func testRunStopsAtFirstFailureAndSaysWhatWasSkipped() async throws {
        let mock = MockAX()
        mock.errorToThrow = MacDriverError(code: "no_text_focus", message: "nothing editable")
        let r = try await MacRunTool(client: mock, allowlistProvider: allow).execute(parameters: [
            "bundle_id": "com.apple.TextEdit",
            "steps": [["action": "type", "text": "x"], ["action": "key", "keys": "return"], ["action": "key", "keys": "cmd+s"]],
        ])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.result.contains("1. type \"x\" → FAILED:") && r.result.contains("nothing editable"), r.result)
        XCTAssertTrue(r.result.contains("2 steps not run"))
    }

    func testChooseReachesTheDriverFromClickAndRun() async throws {
        let mock = MockAX()
        let r = try await MacClickTool(client: mock, allowlistProvider: allow)
            .execute(parameters: ["bundle_id": "com.apple.TextEdit", "title": "File Format", "item": "Plain Text"])
        XCTAssertEqual(mock.lastCall, "choose:File Format:Plain Text"); XCTAssertTrue(r.result.contains("Chose"))
        let run = try await MacRunTool(client: mock, allowlistProvider: allow).execute(parameters: [
            "bundle_id": "com.apple.TextEdit", "read_after": false,
            "steps": [["action": "choose", "title": "File Format", "item": "Plain Text"]],
        ])
        XCTAssertTrue(run.result.contains("1. choose File Format → Plain Text → Chose 'Plain Text'."), run.result)
        let bad = try await MacRunTool(client: mock, allowlistProvider: allow).execute(parameters: [
            "bundle_id": "com.apple.TextEdit", "steps": [["action": "choose", "title": "File Format"]],
        ])
        XCTAssertTrue(bad.isError && bad.result.contains("needs the pop-up"))
    }

    func testRunValidatesStepsBeforeActing() async throws {
        let mock = MockAX()
        let r = try await MacRunTool(client: mock, allowlistProvider: allow).execute(parameters: [
            "bundle_id": "com.apple.TextEdit",
            "steps": [["action": "key", "keys": "cmd+n"], ["action": "fly"]],
        ])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.result.contains("step 2: unknown action 'fly'"))
        XCTAssertEqual(mock.lastCall, "", "nothing ran")
        let tooMany = try await MacRunTool(client: mock, allowlistProvider: allow).execute(parameters: [
            "bundle_id": "com.apple.TextEdit", "steps": Array(repeating: ["action": "key", "keys": "down"], count: 13),
        ])
        XCTAssertTrue(tooMany.isError)
        let denied = try await MacRunTool(client: mock, allowlistProvider: allow).execute(parameters: [
            "bundle_id": "com.apple.mail", "steps": [["action": "key", "keys": "cmd+n"]],
        ])
        XCTAssertTrue(denied.isError)
    }

    /// mac_click with no ref/title/identifier must return an error mentioning "ref"
    /// and must NOT call the driver (lastCall stays empty).
    func testMacClickEmptyTargetReturnsError() async throws {
        let mock = MockAX()
        let r = try await MacClickTool(client: mock, allowlistProvider: allow)
            .execute(parameters: ["bundle_id": "com.apple.TextEdit"])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.result.contains("ref"), "error message should mention 'ref'")
        XCTAssertEqual(mock.lastCall, "", "driver must NOT be called for empty target")
    }
}
#endif
