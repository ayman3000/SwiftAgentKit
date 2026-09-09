// Live check of the Mac driver against real apps (TextEdit, Finder, System Settings).
// Needs Accessibility for the terminal that runs it. Run: swift run -c release
import Foundation
import AppKit
import SwiftAgentKitMac

let client = AXClient()
func check(_ label: String, _ ok: Bool, _ detail: String = "") { print((ok ? "PASS " : "FAIL ") + label + (detail.isEmpty ? "" : "  — " + detail)) }
func quit(_ b: String) { NSRunningApplication.runningApplications(withBundleIdentifier: b).forEach { $0.terminate() }; Thread.sleep(forTimeInterval: 1) }

Task {
    do {
        // 1. Launch waits for a window; first read is non-empty.
        try await client.launch(bundleId: "com.apple.TextEdit")
        var tree = try await client.snapshot(bundleId: "com.apple.TextEdit")
        check("launch waits for a window", tree.renderCompact().contains("AXWindow"))
        if tree.renderCompact().contains("AXSheet") {       // a Save sheet from an earlier session: cancel it, leave the document alone
            try await client.key(bundleId: "com.apple.TextEdit", keys: "escape")
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        // New document via key, then type with verification; then replace.
        try await client.key(bundleId: "com.apple.TextEdit", keys: "cmd+n")
        try await Task.sleep(nanoseconds: 800_000_000)
        var v1 = false
        do { v1 = try await client.type(bundleId: "com.apple.TextEdit", text: "first line\nsecond line", target: nil, replace: false) }
        catch { print("type error: \(error)") }
        check("type verified (two lines)", v1)
        let v2 = try await client.type(bundleId: "com.apple.TextEdit", text: "replaced", target: nil, replace: true)
        tree = try await client.snapshot(bundleId: "com.apple.TextEdit")
        let body = tree.renderCompact()
        check("replace wipes previous text", v2 && body.contains("replaced") && !body.contains("first line"), String(body.split(separator: "\n").first(where: { $0.contains("AXTextArea") }) ?? ""))
        // Key sequence: select all + copy, then paste doubles the text.
        try await client.key(bundleId: "com.apple.TextEdit", keys: "cmd+a, cmd+c, right, cmd+v")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        tree = try await client.snapshot(bundleId: "com.apple.TextEdit")
        let seqLine = tree.renderCompact().split(separator: "\n").first(where: { $0.contains("AXTextArea") && $0.contains("value=") }).map(String.init) ?? "<no text area with value>"
        check("key sequence (select, copy, paste)", tree.renderCompact().contains("replacedreplaced"), seqLine)
        // Filtered read finds the text area only.
        let m = tree.renderMatches("replaced")
        check("mac_ui filter", m.contains("AXTextArea") && m.split(separator: "\n").count <= 4, m.trimmingCharacters(in: .whitespacesAndNewlines))
        // Close doc without saving: cmd+w then "Delete" button by case-insensitive title.
        try await client.key(bundleId: "com.apple.TextEdit", keys: "cmd+w")
        try await Task.sleep(nanoseconds: 700_000_000)
        let how = try await client.click(bundleId: "com.apple.TextEdit", target: MacTarget(title: "delete"), options: MacClickOptions())
        check("click by lowercase title", how.hasPrefix("Pressed"), how)
        // Close every untitled document this and earlier harness runs left behind (never the user's "Untitled").
        for _ in 0..<8 {
            let t = try await client.snapshot(bundleId: "com.apple.TextEdit").renderCompact()
            guard let line = t.split(separator: "\n").first(where: { $0.contains("AXWindow \"Untitled ") }) else { break }
            _ = line
            try await client.key(bundleId: "com.apple.TextEdit", keys: "cmd+w")
            try await Task.sleep(nanoseconds: 600_000_000)
            if (try? await client.click(bundleId: "com.apple.TextEdit", target: MacTarget(title: "Delete"), options: MacClickOptions())) == nil { break }
            try await Task.sleep(nanoseconds: 400_000_000)
        }

        // 1b. mac_run: several steps in one call against TextEdit, verified per step, window read appended.
        let run = MacRunTool(client: client, allowlistProvider: { ["com.apple.TextEdit"] })
        let rr = try await run.execute(parameters: [
            "bundle_id": "com.apple.TextEdit",
            "steps": [["action": "key", "keys": "cmd+n"], ["action": "type", "text": "batch one\nbatch two"],
                      ["action": "key", "keys": "cmd+a, cmd+c"], ["action": "wait", "title": "Untitled 2"]],
            "filter": "batch",
        ])
        check("mac_run batch of four", !rr.isError && rr.result.contains("2. type") && rr.result.contains("typed, verified") && rr.result.contains("4. wait") && rr.result.contains("batch one"), rr.result.split(separator: "\n").prefix(5).joined(separator: " | "))
        try await client.key(bundleId: "com.apple.TextEdit", keys: "cmd+w"); try await Task.sleep(nanoseconds: 600_000_000)
        _ = try? await client.click(bundleId: "com.apple.TextEdit", target: MacTarget(title: "Delete"), options: MacClickOptions())

        // 2. Finder: double-click opens a folder (window title changes).
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("naseem-harness-\(Int(Date().timeIntervalSince1970))")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("InnerFolder"), withIntermediateDirectories: true)
        NSWorkspace.shared.open(tmp)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try await client.key(bundleId: "com.apple.finder", keys: "cmd+2")   // list view
        try await Task.sleep(nanoseconds: 600_000_000)
        let howF = try await client.click(bundleId: "com.apple.finder", target: MacTarget(title: "InnerFolder"), options: MacClickOptions(clicks: 2))
        try await Task.sleep(nanoseconds: 1_200_000_000)
        tree = try await client.snapshot(bundleId: "com.apple.finder")
        check("double-click opens a folder", tree.renderCompact().contains("AXWindow \"InnerFolder\""), howF)
        try await client.key(bundleId: "com.apple.finder", keys: "cmd+w")
        try? FileManager.default.removeItem(at: tmp)

        // 3. System Settings: scroll the sidebar, click 'sound' lowercase (substring/case-insensitive), off-screen guard.
        quit("com.apple.systempreferences")
        try await client.launch(bundleId: "com.apple.systempreferences")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let before = try await client.snapshot(bundleId: "com.apple.systempreferences").renderMatches("Wallpaper")
        try await client.scroll(bundleId: "com.apple.systempreferences", target: nil, direction: "down", amount: 30)
        let after = try await client.snapshot(bundleId: "com.apple.systempreferences").renderMatches("Wallpaper")
        check("scroll changes what is visible", before != after, "")
        let howS = try await client.click(bundleId: "com.apple.systempreferences", target: MacTarget(title: "sound"), options: MacClickOptions())
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let pane = try await client.snapshot(bundleId: "com.apple.systempreferences").renderCompact()
        check("click sidebar row by lowercase substring", pane.contains("Output & Input") || pane.contains("Sound effects") || pane.contains("Play sound"), howS)
        quit("com.apple.systempreferences")
    } catch {
        print("ERROR \(error)")
    }
    exit(0)
}
RunLoop.main.run()
