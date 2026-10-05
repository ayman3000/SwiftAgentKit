import XCTest
@testable import SwiftAgentKitSimulator
import SwiftAgentKit

#if os(macOS)
final class SimRetryAuditTests: XCTestCase {
    private func session() -> SimSession {
        let s = SimSession()
        s.currentBundleId = "com.x"
        return s
    }

    /// Only tools that observe may be retried; a tap or typing twice is a bug.
    func testOnlyObservingSimToolsRetry() {
        let mock = MockDriver()
        XCTAssertTrue(SimUITool(client: mock, session: session()).retriesTransientFailures)
        XCTAssertTrue(SimFindTool(client: mock, session: session()).retriesTransientFailures)
        XCTAssertTrue(SimScreenshotTool(client: mock, session: session()).retriesTransientFailures)
        XCTAssertTrue(SimListTool().retriesTransientFailures)
        XCTAssertFalse(SimTapTool(client: mock, session: session()).retriesTransientFailures)
        XCTAssertFalse(SimTypeTool(client: mock, session: session()).retriesTransientFailures)
        XCTAssertFalse(SimSwipeTool(client: mock, session: session()).retriesTransientFailures)
        XCTAssertFalse(SimLogsTool(session: session()).retriesTransientFailures,
                       "sim_logs starts a stream; a retry would start a second one")
    }

    func testADroppedDriverConnectionIsTransient() async throws {
        let mock = MockDriver()
        mock.errorToThrow = URLError(.networkConnectionLost)
        let ui = try await SimUITool(client: mock, session: session()).execute(parameters: [:])
        XCTAssertTrue(ui.isError)
        XCTAssertTrue(ui.isTransient)
        let shot = try await SimScreenshotTool(client: mock, session: session()).execute(parameters: [:])
        XCTAssertTrue(shot.isTransient)
    }

    func testADriverErrorIsNotTransient() async throws {
        let mock = MockDriver()
        mock.errorToThrow = SimDriverError(code: "not_found", message: "no such element")
        let result = try await SimUITool(client: mock, session: session()).execute(parameters: [:])
        XCTAssertTrue(result.isError)
        XCTAssertFalse(result.isTransient)
    }
}
#endif
