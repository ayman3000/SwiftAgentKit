import XCTest
@testable import SwiftAgentKitSimulator

final class SimWireSyncTests: XCTestCase {
    func testDriverCopyOfSimWireIsByteIdentical() throws {
        // Canonical: located via #filePath so this works from a package checkout too.
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let pkgRoot = testsDir.deletingLastPathComponent().deletingLastPathComponent()
        let canonical = pkgRoot.appendingPathComponent("Sources/SwiftAgentKitSimulator/SimWire.swift")
        let driverCopy = pkgRoot.appendingPathComponent(
            "Sources/SwiftAgentKitSimulator/Resources/SimDriverProject/SimDriverUITests/SimWire.swift")
        let a = try Data(contentsOf: canonical)
        let b = try Data(contentsOf: driverCopy)
        XCTAssertEqual(a, b, "Driver's SimWire.swift drifted — run: cp Sources/SwiftAgentKitSimulator/SimWire.swift Sources/SwiftAgentKitSimulator/Resources/SimDriverProject/SimDriverUITests/SimWire.swift")
    }
}
