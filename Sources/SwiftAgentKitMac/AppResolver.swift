#if os(macOS)
import Foundation
import AppKit

public enum AppResolver {
    public static func runningApps() -> [(name: String, bundleId: String)] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (String, String)? in
                guard let bid = app.bundleIdentifier else { return nil }
                let name = app.localizedName ?? bid
                return (name, bid)
            }
            .filter { seen.insert($0.1).inserted }
            .sorted { $0.0 < $1.0 }
    }

    public static func filterAllowed(_ apps: [(name: String, bundleId: String)],
                                     allowlist: Set<String>) -> [(name: String, bundleId: String)] {
        apps.filter { allowlist.contains($0.bundleId) }
    }

    public static func pid(forBundleId bundleId: String) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.processIdentifier
    }

    public static func launch(bundleId: String) async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            throw MacDriverError(code: "not_found", message: "no installed app with bundle id \(bundleId)")
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }
}
#endif
