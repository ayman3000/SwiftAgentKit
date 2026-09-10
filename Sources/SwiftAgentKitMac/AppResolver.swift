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

    /// Whether the app at `path` answers AppleScript: it declares scripting in
    /// its Info.plist (NSAppleScriptEnabled / OSAScriptingDefinition) or ships
    /// a scripting definition file. Apple's own apps mostly do; most third-party
    /// apps do not, and those must be driven through the mac_* tools.
    public static func isScriptable(appAt path: String) -> Bool {
        guard let bundle = Bundle(path: path) else { return false }
        let info = bundle.infoDictionary ?? [:]
        if let flag = info["NSAppleScriptEnabled"] as? Bool, flag { return true }
        if let flag = info["NSAppleScriptEnabled"] as? String, flag.lowercased() == "yes" { return true }
        if info["OSAScriptingDefinition"] != nil { return true }
        let resources = path + "/Contents/Resources"
        if let items = try? FileManager.default.contentsOfDirectory(atPath: resources),
           items.contains(where: { $0.hasSuffix(".sdef") }) { return true }
        return false
    }

    /// Installed apps whose name contains `name` (case-insensitive), running or
    /// not: the standard app folders plus whatever is running. Best match first.
    public static func installedApps(matching name: String) -> [(name: String, bundleId: String, path: String)] {
        let needle = name.lowercased().replacingOccurrences(of: ".app", with: "")
        guard !needle.isEmpty else { return [] }
        var out: [(String, String, String)] = []
        var seen: Set<String> = []
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                    fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        for dir in dirs {
            for entry in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where entry.hasSuffix(".app") {
                let appName = String(entry.dropLast(4))
                guard appName.lowercased().contains(needle) else { continue }
                let path = dir + "/" + entry
                guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier, !seen.contains(id) else { continue }
                seen.insert(id)
                out.append((appName, id, path))
            }
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, !seen.contains(id),
                  (app.localizedName ?? "").lowercased().contains(needle) else { continue }
            seen.insert(id)
            out.append((app.localizedName ?? id, id, app.bundleURL?.path ?? ""))
        }
        // Exact name first, then shortest name (closest match).
        return out.sorted { a, b in
            let ae = a.0.lowercased() == needle, be = b.0.lowercased() == needle
            if ae != be { return ae }
            return a.0.count < b.0.count
        }
    }

    public static func launch(bundleId: String) async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            // A name or a guessed id: point at the real id instead of a dead end.
            let guess = installedApps(matching: bundleId.split(separator: ".").last.map(String.init) ?? bundleId)
                + installedApps(matching: bundleId)
            if let hit = guess.first {
                throw MacDriverError(code: "not_found",
                                     message: "No installed app with bundle id '\(bundleId)'. Did you mean \(hit.name) — \(hit.bundleId)? "
                                     + "Call mac_launch with that bundle id.")
            }
            throw MacDriverError(code: "not_found",
                                 message: "No installed app with bundle id '\(bundleId)'. Look the app up by name with mac_apps (name: \"…\").")
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }
}
#endif
