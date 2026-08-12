#if os(macOS)
import XCTest
@testable import SwiftAgentKitSimulator

/// End-to-end against a REAL simulator. Requires full Xcode + an iOS runtime.
/// Run: SAK_LIVE_TESTS=1 SAK_SIM_TESTS=1 swift test --filter SimLiveTests
final class SimLiveTests: XCTestCase {

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["SAK_LIVE_TESTS"] == "1",
              ProcessInfo.processInfo.environment["SAK_SIM_TESTS"] == "1" else {
            throw XCTSkip("live simulator tests gated behind SAK_LIVE_TESTS=1 SAK_SIM_TESTS=1")
        }
    }

    func testDriveSettingsApp() async throws {
        // 1. Find or boot a simulator.
        var device = try await Simctl.bootedDevice()
        if device == nil {
            let candidates = try await Simctl.listDevices().filter { $0.runtime.contains("iOS") }
            let chosen = try XCTUnwrap(candidates.last, "no iOS simulators available")
            try await Simctl.boot(udid: chosen.udid)
            device = chosen
        }
        let dev = try XCTUnwrap(device)

        // 2. Build (first run ~30-60s) + launch the driver, wait healthy.
        let manager = SimDriverManager()
        try await manager.launch(udid: dev.udid, runtime: dev.runtime)
        addTeardownBlock { await manager.shutdown() }

        // 3. Connect the client.
        let client = await SimClient(manager: manager, udid: dev.udid, runtime: dev.runtime)

        // 4. Launch Settings, wait for "General" to appear, assert it's in the tree.
        try await client.launch(bundleId: "com.apple.Preferences", terminateFirst: true)

        // iOS 26 / Settings may label the row "General" at the cell level. Extend
        // timeout generously because the app sometimes needs a moment to populate.
        let tree: UITree
        do {
            tree = try await client.waitFor(
                bundleId: "com.apple.Preferences",
                target: .init(label: "General"),
                timeoutSeconds: 20,
                forDisappearance: false
            )
        } catch let e as SimDriverError where e.code == "timeout" {
            // Dump the actual tree so we can adapt label expectations in future runs.
            let snap = try await client.snapshot(bundleId: "com.apple.Preferences")
            XCTFail("waitFor 'General' timed out. Actual tree:\n\(snap.renderCompact())")
            return
        }
        XCTAssertTrue(tree.renderCompact().contains("General"),
                      "Settings root should contain a General element")

        // 5. Tap General → wait for "About" to confirm navigation.
        try await client.tap(bundleId: "com.apple.Preferences",
                             target: .init(label: "General"),
                             longPress: false)

        let after: UITree
        do {
            after = try await client.waitFor(
                bundleId: "com.apple.Preferences",
                target: .init(label: "About"),
                timeoutSeconds: 20,
                forDisappearance: false
            )
        } catch let e as SimDriverError where e.code == "timeout" {
            let snap = try await client.snapshot(bundleId: "com.apple.Preferences")
            XCTFail("waitFor 'About' timed out after tapping General. Actual tree:\n\(snap.renderCompact())")
            return
        }
        XCTAssertTrue(after.renderCompact().contains("About"),
                      "tapping General must navigate to a screen containing 'About'")

        // 6. Screenshot returns a real PNG (≥10 KB, PNG magic bytes 89 50 4E 47).
        let png = try await client.screenshot()
        XCTAssertGreaterThan(png.count, 10_000, "screenshot should be >10 KB")
        XCTAssertEqual(png.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]),
                       "screenshot must be a PNG (magic bytes 89 50 4E 47)")
    }
}
#endif
