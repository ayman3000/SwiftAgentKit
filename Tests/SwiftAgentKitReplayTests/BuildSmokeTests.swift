import Testing
@testable import SwiftAgentKitReplay

@Test func replayHarnessModuleBuildsAndImports() {
    #expect(ReplayHarness.version == "1.0")
}
