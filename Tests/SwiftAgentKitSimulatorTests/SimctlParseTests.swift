import XCTest
@testable import SwiftAgentKitSimulator

#if os(macOS)
final class SimctlParseTests: XCTestCase {
    func testParsesBootedAndShutdownDevices() throws {
        let json = """
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-26-1": [
            {"udid": "AAAA-1111", "name": "iPhone 17 Pro Max", "state": "Booted", "isAvailable": true},
            {"udid": "BBBB-2222", "name": "iPhone 17", "state": "Shutdown", "isAvailable": true}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-25-0": []
        }}
        """.data(using: .utf8)!
        let devices = try Simctl.parseDevices(json: json)
        XCTAssertEqual(devices.count, 2)
        let booted = devices.first { $0.isBooted }
        XCTAssertEqual(booted?.udid, "AAAA-1111")
        XCTAssertEqual(booted?.runtime, "com.apple.CoreSimulator.SimRuntime.iOS-26-1")
    }
}
#endif
