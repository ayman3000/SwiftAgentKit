#if os(macOS)
import ApplicationServices

/// How to click: single/double, left/right.
public struct MacClickOptions: Sendable, Equatable {
    public var clicks: Int
    public var rightButton: Bool
    public init(clicks: Int = 1, rightButton: Bool = false) { self.clicks = clicks; self.rightButton = rightButton }
}

public protocol AXDriving: Sendable {
    func isTrusted() -> Bool
    func snapshot(bundleId: String) async throws -> UITree
    /// Returns a short note on how the click was delivered (pressed, selected, mouse…).
    func click(bundleId: String, target: MacTarget, options: MacClickOptions) async throws -> String
    /// Returns true when the text was read back from the focused field.
    /// `replace` selects the field's existing content first so the text replaces it.
    func type(bundleId: String, text: String, target: MacTarget?, replace: Bool) async throws -> Bool
    /// One combo ("cmd+s") or a comma-separated sequence ("cmd+a, cmd+c").
    func key(bundleId: String, keys: String) async throws
    /// Scroll wheel over `target` (or the app's front window). Direction up/down/left/right.
    func scroll(bundleId: String, target: MacTarget?, direction: String, amount: Int) async throws
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
