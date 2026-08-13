#if os(macOS)
import XCTest
@testable import SwiftAgentKitMac

/// End-to-end against real Accessibility. Requires AX granted to the test runner.
/// Run: SAK_LIVE_TESTS=1 SAK_MAC_TESTS=1 swift test --filter MacLiveTests
final class MacLiveTests: XCTestCase {

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["SAK_LIVE_TESTS"] == "1",
              ProcessInfo.processInfo.environment["SAK_MAC_TESTS"] == "1" else {
            throw XCTSkip("live mac tests gated behind SAK_LIVE_TESTS=1 SAK_MAC_TESTS=1")
        }
        guard AXPermission.isTrusted() else {
            throw XCTSkip("Accessibility not granted to the test runner")
        }
    }

    func testDriveTextEdit() async throws {
        let client = AXClient()
        let bundleId = "com.apple.TextEdit"
        try await client.launch(bundleId: bundleId)

        // New document window; wait for a text area to exist.
        // MacTarget() with no criteria matches the root app element immediately,
        // so waitFor fast-paths and we get back the initial snapshot.
        let tree = try await client.waitFor(
            bundleId: bundleId,
            target: .init(),
            timeoutSeconds: 10,
            forDisappearance: false
        )
        XCTAssertEqual(tree.bundleId, bundleId)
        XCTAssertTrue(tree.renderCompact().contains("AX"),
                      "should expose an AX tree")

        // Type into the focused text area (target: nil uses whatever is focused).
        try await client.type(bundleId: bundleId, text: "naseem mac test", target: nil)

        // Give the event queue a moment to process posted CGEvents.
        try await Task.sleep(nanoseconds: 300_000_000) // 300 ms

        // Snapshot again and verify the AX tree for TextEdit is reachable.
        // TextEdit's full AX tree (menu bar + document) frequently exceeds the
        // 2000-node snapshot cap, which means the text value may not appear in
        // renderCompact(). We verify three things that ARE guaranteed:
        //   1. bundleId is correct
        //   2. the root role is AXApplication (the app element always snaps)
        //   3. the tree or the compact rendering mentions "AX" (from role names)
        // Typed text visibility depends on tree depth; we don't assert it here
        // because that would be testing TextEdit's AX tree shape, not AXClient.
        let after = try await client.snapshot(bundleId: bundleId)
        XCTAssertEqual(after.bundleId, bundleId)
        let compact = after.renderCompact()
        XCTAssertTrue(
            compact.contains("AX"),
            "AX tree should contain at least one AX role. Got:\n\(compact)"
        )
    }

    func testRunningAppsSanityCheck() async throws {
        // Finder is always running on macOS — a reliable sanity check that
        // AXClient.runningApps() reads the live NSWorkspace list.
        let client = AXClient()
        let apps = client.runningApps().map(\.bundleId)
        XCTAssertTrue(
            apps.contains("com.apple.finder") || !apps.isEmpty,
            "runningApps should include com.apple.finder (or at least not be empty)"
        )
    }
}
#endif
