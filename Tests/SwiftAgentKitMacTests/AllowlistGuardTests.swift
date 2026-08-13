import XCTest
@testable import SwiftAgentKitMac
import SwiftAgentKit

#if os(macOS)
final class AllowlistGuardTests: XCTestCase {
    func testDeniesWhenBundleNotAllowed() {
        let r = AllowlistGuard.resolve(["bundle_id": "com.apple.mail"],
                    allowlist: ["com.apple.Notes"], toolName: "mac_ui", requireBundleId: true)
        guard case .failure(let err) = r else { return XCTFail("expected denial") }
        XCTAssertTrue(err.isError)
        XCTAssertTrue(err.result.contains("not permitted"))
    }
    func testAllowsWhenBundleAllowed() {
        let r = AllowlistGuard.resolve(["bundle_id": "com.apple.Notes"],
                    allowlist: ["com.apple.Notes"], toolName: "mac_ui", requireBundleId: true)
        guard case .success(let b) = r else { return XCTFail("expected allow") }
        XCTAssertEqual(b, "com.apple.Notes")
    }
    func testEmptyAllowlistAlwaysDenies() {
        let r = AllowlistGuard.resolve(["bundle_id": "com.apple.Notes"],
                    allowlist: [], toolName: "mac_ui", requireBundleId: true)
        guard case .failure = r else { return XCTFail("expected denial") }
    }
    func testMissingBundleIdIsError() {
        let r = AllowlistGuard.resolve([:], allowlist: ["com.apple.Notes"],
                    toolName: "mac_ui", requireBundleId: true)
        guard case .failure(let err) = r else { return XCTFail("expected error") }
        XCTAssertTrue(err.result.contains("bundle_id"))
    }
}
#endif
