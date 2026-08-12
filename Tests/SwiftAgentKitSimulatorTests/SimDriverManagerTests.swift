import XCTest
@testable import SwiftAgentKitSimulator

#if os(macOS)
final class SimDriverManagerTests: XCTestCase {
    func testCacheDirectoryIsPerXcodeAndRuntime() {
        let a = SimDriverManager.cacheDirectory(xcodeVersion: "26.1",
                    runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-1")
        let b = SimDriverManager.cacheDirectory(xcodeVersion: "26.2",
                    runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-1")
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.path.contains("SwiftAgentKitSimulator/26.1-iOS-26-1"))
        XCTAssertFalse(a.path.contains("com.apple.CoreSimulator"), "runtime prefix stripped for readability")
    }
}
#endif
