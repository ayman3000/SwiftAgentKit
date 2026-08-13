#if os(macOS)
import ApplicationServices

public protocol AXDriving: Sendable {
    func isTrusted() -> Bool
    func snapshot(bundleId: String) async throws -> UITree
    func click(bundleId: String, target: MacTarget) async throws
    func type(bundleId: String, text: String, target: MacTarget?) async throws
    func key(bundleId: String, keys: String) async throws
    func waitFor(bundleId: String, target: MacTarget, timeoutSeconds: Double, forDisappearance: Bool) async throws -> UITree
    func launch(bundleId: String) async throws
    func runningApps() -> [(name: String, bundleId: String)]
}

public enum AXPermission {
    public static func isTrusted() -> Bool { AXIsProcessTrusted() }

    @discardableResult
    public static func promptForTrust() -> Bool {
        let key = "AXTrustedCheckOptionPrompt"
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
#endif
