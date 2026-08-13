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
}
#endif
