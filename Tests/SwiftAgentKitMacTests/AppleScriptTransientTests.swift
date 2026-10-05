import Testing
import SwiftAgentKit
@testable import SwiftAgentKitMac

#if os(macOS)
struct AppleScriptTransientTests {
    @Test func aStillLaunchingAppIsTransient() {
        #expect(AppleScriptError(code: -609, message: "Connection is invalid.").isTransient)
        #expect(ToolRetry.isTransient(AppleScriptError(code: -609, message: "x")))
    }

    /// A timed-out Apple Event already waited the script's own 120 s: a
    /// retry would double a slow Mail/Notes read, so it is not retried.
    @Test func aTimedOutAppleEventIsNotRetried() {
        #expect(!AppleScriptError(code: -1712, message: "AppleEvent timed out.").isTransient)
        #expect(!ToolRetry.isTransient(AppleScriptError(code: -1712, message: "x")))
    }

    @Test func permissionAndScriptErrorsAreNot() {
        #expect(!AppleScriptError(code: -1743, message: "Not authorized.").isTransient)
        #expect(!AppleScriptError(code: -600, message: "Not running.").isTransient)
        #expect(!AppleScriptError(code: -1, message: "Could not compile.").isTransient)
    }
}
#endif
