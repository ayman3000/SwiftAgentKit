import XCTest
@testable import SwiftAgentKitMac

#if os(macOS)
final class AppResolverTests: XCTestCase {
    func testFilterAllowedKeepsOnlyAllowlisted() {
        let apps = [("Notes", "com.apple.Notes"),
                    ("Mail", "com.apple.mail"),
                    ("Safari", "com.apple.Safari")]
        let filtered = AppResolver.filterAllowed(apps, allowlist: ["com.apple.Notes", "com.apple.Safari"])
        XCTAssertEqual(filtered.map(\.bundleId), ["com.apple.Notes", "com.apple.Safari"])
    }

    func testFilterAllowedEmptyAllowlistYieldsNothing() {
        let apps = [("Notes", "com.apple.Notes")]
        XCTAssertTrue(AppResolver.filterAllowed(apps, allowlist: []).isEmpty)
    }

    /// Reading the agent's own app through Accessibility runs its SwiftUI
    /// views on the calling background thread, which traps (1.18.0 crash).
    /// Another copy with the same bundle id is a separate process and fine.
    func testOwnProcessIsNeverTheTarget() {
        XCTAssertNil(AppResolver.pid(in: [42], own: 42))
        XCTAssertEqual(AppResolver.pid(in: [42, 77], own: 42), 77)
        XCTAssertEqual(AppResolver.pid(in: [77], own: 42), 77)
        XCTAssertNil(AppResolver.pid(in: [], own: 42))
    }

    func testDrivingTheOwnAppIsRefusedWithAClearMessage() throws {
        let own = try XCTUnwrap(AppResolver.pid(in: [AppResolver.ownPid], own: 0))
        XCTAssertThrowsError(try AXClient.refuseOwnProcess(own, bundleId: "com.example.agent")) { error in
            let e = error as? MacDriverError
            XCTAssertEqual(e?.code, "own_app")
            XCTAssertTrue(e?.message.contains("own window") ?? false)
        }
        XCTAssertNoThrow(try AXClient.refuseOwnProcess(own + 1, bundleId: "com.apple.TextEdit"))
    }
}
#endif
