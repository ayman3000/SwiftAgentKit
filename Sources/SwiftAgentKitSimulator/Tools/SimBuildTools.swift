#if os(macOS)
import Foundation
import SwiftAgentKit
import Darwin

// MARK: - SimBuildInstallTool

/// Builds an Xcode project/workspace and installs the resulting app in the booted simulator.
/// Requires confirmation — triggers a real build.
public struct SimBuildInstallTool: AgentTool {
    public let name = "sim_build_install"
    public let description = """
    Build an Xcode project or workspace and install the resulting app in the currently \
    booted simulator. Provide `project_path` (.xcodeproj or .xcworkspace), `scheme`, \
    and optional `configuration` (default: Debug). The app's bundle ID is read from \
    Info.plist and set as the active target for subsequent sim_* calls.
    """
    public let parameters = ToolParameters(
        properties: [
            "project_path": ToolParameterProperty(type: "string",
                description: "Path to the .xcodeproj or .xcworkspace file."),
            "scheme": ToolParameterProperty(type: "string",
                description: "Xcode scheme to build."),
            "configuration": ToolParameterProperty(type: "string",
                description: "Build configuration (default: Debug)."),
        ],
        required: ["project_path", "scheme"])
    public var requiresConfirmation: Bool { true }

    let session: SimSession
    public init(session: SimSession) { self.session = session }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let udid = session.udid else {
            return .error(toolCallId: "", toolName: name,
                message: "No simulator is booted. Boot one first with sim_boot.")
        }
        guard let projectPath = parameters["project_path"] as? String, !projectPath.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "sim_build_install requires `project_path`.")
        }
        guard let scheme = parameters["scheme"] as? String, !scheme.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "sim_build_install requires `scheme`.")
        }
        let configuration = (parameters["configuration"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Debug"

        let projectURL = URL(fileURLWithPath: (projectPath as NSString).expandingTildeInPath)
        let projectDir = projectURL.deletingLastPathComponent().path
        let derivedDataPath = projectDir + "/.sak-derived"

        // Choose -project or -workspace flag based on file extension
        let ext = projectURL.pathExtension.lowercased()
        let projectFlag = ext == "xcworkspace" ? "-workspace" : "-project"

        let args: [String] = [
            "xcodebuild",
            projectFlag, projectURL.path,
            "-scheme", scheme,
            "-configuration", configuration,
            "-destination", "id=\(udid)",
            "-derivedDataPath", derivedDataPath,
            "build",
        ]

        do {
            let (status, output) = try await Simctl.run(args, timeout: 1800)
            guard status == 0 else {
                let tail = output.count > 6000 ? String(output.suffix(6000)) : output
                return .error(toolCallId: "", toolName: name,
                    message: "xcodebuild failed (exit \(status)):\n\(tail)")
            }

            // Find the newest .app under .sak-derived/Build/Products/*-iphonesimulator/
            let productsDir = derivedDataPath + "/Build/Products"
            guard let appURL = Self.newestApp(in: productsDir) else {
                return .error(toolCallId: "", toolName: name,
                    message: "Build succeeded but no .app found under \(productsDir).")
            }

            // Read CFBundleIdentifier from Info.plist
            let infoPlistURL = appURL.appendingPathComponent("Info.plist")
            guard let plistData = try? Data(contentsOf: infoPlistURL),
                  let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
                  let bundleId = plist["CFBundleIdentifier"] as? String, !bundleId.isEmpty
            else {
                return .error(toolCallId: "", toolName: name,
                    message: "Could not read CFBundleIdentifier from \(infoPlistURL.path).")
            }

            // Install via simctl
            try await Simctl.install(udid: udid, appPath: appURL.path)
            session.currentBundleId = bundleId

            return .success(toolCallId: "", toolName: name,
                result: "Built and installed \(bundleId) [\(appURL.lastPathComponent)] on \(udid).")
        } catch {
            return .error(toolCallId: "", toolName: name,
                message: "sim_build_install failed: \(error.localizedDescription)")
        }
    }

    /// Finds the newest `.app` bundle under `productsDir/*-iphonesimulator/`.
    /// Pure static helper — testable without spawning processes.
    public static func newestApp(in productsDir: String) -> URL? {
        let fm = FileManager.default
        let productsDirURL = URL(fileURLWithPath: productsDir)

        // Enumerate *-iphonesimulator subdirectories
        guard let subdirs = try? fm.contentsOfDirectory(
            at: productsDirURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let simDirs = subdirs.filter {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: $0.path, isDirectory: &isDir)
            return isDir.boolValue && $0.lastPathComponent.hasSuffix("-iphonesimulator")
        }

        // Collect all .app bundles across those dirs
        var candidates: [(url: URL, modDate: Date)] = []
        for simDir in simDirs {
            guard let entries = try? fm.contentsOfDirectory(
                at: simDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries where entry.pathExtension.lowercased() == "app" {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let modDate = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                candidates.append((url: entry, modDate: modDate))
            }
        }

        // Return the newest by modification date
        return candidates.max(by: { $0.modDate < $1.modDate })?.url
    }
}

// MARK: - SimLogsRegistry

/// Lock-protected registry of pids spawned by SimLogsTool.
/// Only pids in this registry are reaped or accepted for stop requests.
/// NEVER call waitpid(-1,…) — it steals Foundation.Process exit statuses.
enum SimLogsRegistry {
    static let lock = NSLock()
    // nonisolated(unsafe): all accesses are serialised through `lock`.
    nonisolated(unsafe) static var pids = Set<pid_t>()

    static func insert(_ pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        pids.insert(pid)
    }

    static func remove(_ pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        pids.remove(pid)
    }

    static func contains(_ pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pids.contains(pid)
    }

    /// Non-blocking reap of any already-exited children in the registry.
    static func reapExited() {
        lock.lock()
        let snapshot = pids
        lock.unlock()
        for pid in snapshot {
            let result = waitpid(pid, nil, WNOHANG)
            if result > 0 {
                lock.lock(); pids.remove(pid); lock.unlock()
            }
        }
    }
}

// MARK: - SimLogsTool

/// Spawns a detached `xcrun simctl spawn … log stream` writing to a temp file.
/// A second call with `stop: true` + `pid` kills a previous stream.
public struct SimLogsTool: AgentTool {
    public let name = "sim_logs"
    public let description = """
    Stream simulator app logs to a temp file (non-blocking). Returns the pid and log \
    path immediately. Call again with `stop: true` and the `pid` from the first call \
    to stop streaming. Uses `bundle_id` if provided, else the currently active app.
    """
    public let parameters = ToolParameters(
        properties: [
            "bundle_id": ToolParameterProperty(type: "string",
                description: "Bundle ID to filter logs; defaults to the active app."),
            "stop": ToolParameterProperty(type: "boolean",
                description: "If true, kill the stream process identified by `pid`."),
            "pid": ToolParameterProperty(type: "integer",
                description: "PID returned by a previous sim_logs call; required when stop=true."),
        ],
        required: [])
    /// Read-only log tap — no destructive side effects.
    public var requiresConfirmation: Bool { false }

    let session: SimSession
    public init(session: SimSession) { self.session = session }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        // Handle stop request
        if (parameters["stop"] as? Bool) == true {
            guard let rawPid = parameters["pid"].flatMap({ $0 as? Int }) else {
                return .error(toolCallId: "", toolName: name, message: "sim_logs stop=true requires `pid`.")
            }
            let pid = Int32(rawPid)
            guard pid > 0 else {
                return .error(toolCallId: "", toolName: name, message: "sim_logs: invalid pid \(rawPid).")
            }
            // Only accept pids that were started by sim_logs in this process.
            guard SimLogsRegistry.contains(pid) else {
                return .error(toolCallId: "", toolName: name,
                    message: "pid \(pid) was not started by sim_logs.")
            }
            kill(-pid, SIGTERM)   // terminate the process group
            kill(pid, SIGTERM)    // belt-and-suspenders for single-process case
            usleep(20_000)        // 20 ms — give child a moment to exit
            // Non-blocking reap of this specific pid only.
            waitpid(pid, nil, WNOHANG)
            SimLogsRegistry.remove(pid)
            return .success(toolCallId: "", toolName: name, result: "Stopped log stream (pid \(pid)).")
        }

        guard let udid = session.udid else {
            return .error(toolCallId: "", toolName: name,
                message: "No simulator is booted. Boot one first with sim_boot.")
        }

        let bundleId: String
        if let explicit = parameters["bundle_id"] as? String, !explicit.isEmpty {
            bundleId = explicit
        } else if let current = session.currentBundleId {
            bundleId = current
        } else {
            return .error(toolCallId: "", toolName: name,
                message: "No active app. Provide `bundle_id` or call sim_launch first.")
        }

        // Fix 1: Defensively reject bundle IDs containing a double-quote (would break the predicate argument).
        guard !bundleId.contains("\"") else {
            return .error(toolCallId: "", toolName: name,
                message: "sim_logs: bundle_id must not contain a double-quote character.")
        }

        // Opportunistically reap any previously exited registry children before spawning a new one.
        // Only reaps pids we own — never calls waitpid(-1,…) which would steal Foundation.Process statuses.
        SimLogsRegistry.reapExited()

        // Fix 4: Create a unique temp log file via mkstemps, keeping the fd open for dup2.
        // We do NOT close the fd before spawn — it is dup2'd into the child's stdout/stderr
        // via posix_spawn_file_actions, eliminating the close-then-reopen TOCTTOU window.
        let templateStr = FileManager.default.temporaryDirectory.path + "/sim_logs-XXXXXX.log"
        var logPath: String = ""
        var logFD: Int32 = -1
        templateStr.withCString { src in
            let buf = UnsafeMutablePointer<CChar>.allocate(capacity: strlen(src) + 1)
            _ = strcpy(buf, src)
            logFD = mkstemps(buf, 4)   // 4 = length of ".log"; fd stays open
            logPath = String(cString: buf)
            buf.deallocate()
        }

        guard logFD >= 0 else {
            return .error(toolCallId: "", toolName: name, message: "Failed to create temp log file.")
        }

        // Fix 1: Eliminate the shell layer entirely — posix_spawn xcrun directly with an argv array.
        // The predicate is passed as a single argv element; no shell parsing ever happens.
        let predicate = "processImagePath CONTAINS[c] \"\(bundleId)\""
        let argv: [String] = [
            "xcrun", "simctl", "spawn", udid,
            "log", "stream", "--style", "compact",
            "--predicate", predicate,
        ]
        let xcrunPath = "/usr/bin/xcrun"

        // Fix 4: dup2 the still-open logFD into child stdout/stderr via file actions.
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, logFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, logFD, STDERR_FILENO)
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        // Close the original fd in the child after the dup2s (child only needs fds 0/1/2).
        posix_spawn_file_actions_addclose(&fileActions, logFD)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setpgroup(&attr, 0)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))

        var cStrings: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cStrings.append(nil)
        var pid: pid_t = 0
        let rc = cStrings.withUnsafeBufferPointer { buf in
            posix_spawn(&pid, xcrunPath, &fileActions, &attr, buf.baseAddress!, environ)
        }
        cStrings.forEach { free($0) }

        // Fix 4: Close logFD in the parent after spawn (child has its own copy via dup2).
        close(logFD)

        guard rc == 0 else {
            return .error(toolCallId: "", toolName: name,
                message: "Failed to spawn log stream: \(String(cString: strerror(rc)))")
        }

        // Register pid so the stop path and reapExited() can operate on it safely.
        SimLogsRegistry.insert(pid)

        return .success(toolCallId: "", toolName: name,
            result: "Log stream started (pid \(pid)). Logs → \(logPath)\nCall sim_logs with stop=true and pid=\(pid) to stop.")
    }
}
#endif
