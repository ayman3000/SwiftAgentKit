//
//  ShellTool.swift
//  SwiftAgentKitTools
//
//  A real shell/terminal tool. Confirmation required — it can run anything.
//  macOS-only: `Process` + `/bin/zsh` aren't available on iOS/tvOS/watchOS.
//

#if os(macOS)
import Foundation
import SwiftAgentKit
import Darwin

/// Run a shell command via `zsh` and return its combined stdout/stderr + exit code.
/// Always `requiresConfirmation` — the app must approve each invocation.
///
/// The command runs in its **own process group** (via `posix_spawn` with
/// `POSIX_SPAWN_SETPGROUP`) so that on timeout or cancellation we can SIGKILL the
/// entire tree — including grandchildren that a plain `Process.terminate()` would
/// leave orphaned. That orphan problem is exactly what makes a naïve
/// `readDataToEndOfFile()` hang forever: a surviving child (e.g. a `ng serve` /
/// `npm start` dev server) keeps the stdout pipe's write-end open, so EOF never
/// arrives. Killing the group closes the pipe and unblocks the read.
public struct ShellTool: AgentTool {
    public let name = "run_shell"
    public let description = """
    Run a shell command on this Mac via zsh and return its combined stdout/stderr \
    and exit code. Use for terminal tasks (listing files, git, build commands). \
    Every call must be approved by the user. Optionally set `working_directory`. \
    For long-lived servers (e.g. `npm start`, `ng serve`, `vite`) set \
    `background: true` (auto-detected for common dev servers) — the command keeps \
    running and the tool returns immediately with its pid and any startup output.
    """
    public let parameters = ToolParameters(
        properties: [
            "command": ToolParameterProperty(type: "string", description: "The shell command to run, e.g. `ls -la`."),
            "working_directory": ToolParameterProperty(type: "string", description: "Directory to run in (a leading ~ is expanded)."),
            "background": ToolParameterProperty(type: "boolean", description: "Run detached for long-lived servers; returns immediately with the pid instead of waiting for exit."),
        ],
        required: ["command"]
    )

    public var requiresConfirmation: Bool { true }

    /// Directory used when the model doesn't specify `working_directory`. Apps can
    /// default this to the user's home for terminal-like behavior.
    private let defaultWorkingDirectory: URL?
    private let maxOutputChars: Int
    /// Wall-clock limit; a foreground command exceeding it has its whole process
    /// group killed so a hung process (or one whose child keeps stdout open) never
    /// blocks the agent forever.
    private let timeoutSeconds: Double
    /// How long a `background` command is observed before returning, to capture
    /// startup output (a server's "listening on…" line) without waiting for exit.
    private let backgroundGraceSeconds: Double

    public init(
        defaultWorkingDirectory: URL? = nil,
        maxOutputChars: Int = 10_000,
        timeoutSeconds: Double = 120,
        backgroundGraceSeconds: Double = 2.5
    ) {
        self.defaultWorkingDirectory = defaultWorkingDirectory
        self.maxOutputChars = maxOutputChars
        self.timeoutSeconds = timeoutSeconds
        self.backgroundGraceSeconds = backgroundGraceSeconds
    }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let command = (parameters["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty
        else {
            return .error(toolCallId: "", toolName: name, message: "run_shell requires a non-empty `command`.")
        }

        let cwd = resolveWorkingDirectory(parameters)
        let background = (parameters["background"] as? Bool) ?? Self.looksLikeLongLivedServer(command)

        return background
            ? await runBackground(command: command, cwd: cwd)
            : await runForeground(command: command, cwd: cwd)
    }

    // MARK: - Foreground

    /// Run to completion, capturing output via a pipe. The read-to-EOF is raced
    /// against the wall-clock timeout and cooperative task cancellation; whichever
    /// "stop" fires first SIGKILLs the whole process group, which closes the pipe
    /// and unblocks the read.
    private func runForeground(command: String, cwd: String?) async -> AgentToolResult {
        let pipe = Pipe()
        let writeFD = pipe.fileHandleForWriting.fileDescriptor
        // Mark both ends close-on-exec so unrelated concurrent spawns don't inherit
        // this pipe and hold its write-end open (which would defeat EOF). Our own
        // child still gets stdout via the dup2 file-action (dup2 clears CLOEXEC on
        // the target fd), so fd 1/2 survive its exec.
        setCloseOnExec(pipe.fileHandleForReading.fileDescriptor)
        setCloseOnExec(writeFD)

        let pid: pid_t
        do {
            pid = try spawnInNewGroup(command: command, workingDirectory: cwd, stdoutFD: writeFD)
        } catch {
            return .error(toolCallId: "", toolName: name, message: "Failed to launch shell: \(error.localizedDescription)")
        }
        // Close our copy of the write end so EOF is reached once the child (and
        // everything it spawned) has closed it.
        try? pipe.fileHandleForWriting.close()

        let handle = pipe.fileHandleForReading
        let readTask = Task.detached { handle.readDataToEndOfFile() }

        let stop: StopReason = await withTaskCancellationHandler {
            await withTaskGroup(of: StopReason.self) { group in
                group.addTask {
                    _ = await readTask.value          // read reached EOF on its own
                    return .finished
                }
                group.addTask { [timeoutSeconds] in
                    try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    return .timedOut
                }
                let first = await group.next() ?? .finished
                // Kill BEFORE draining the group: the read child awaits the
                // non-cancellable readDataToEndOfFile, so it only returns once the
                // pipe closes — which killing the group makes happen.
                if first != .finished { killGroup(pid) }
                group.cancelAll()
                return first
            }
        } onCancel: {
            killGroup(pid)                            // Stop button → kill immediately
        }

        let data = await readTask.value              // unblocked; collects partial output
        let status = reap(pid)
        let cancelled = Task.isCancelled

        var output = decode(data)
        let header: String
        if cancelled {
            header = "stopped by user"
        } else if stop == .timedOut {
            header = "exit \(status.exitCode) (terminated after \(Int(timeoutSeconds))s timeout)"
        } else {
            header = "exit \(status.exitCode)"
        }
        if output.count > maxOutputChars {
            output = String(output.prefix(maxOutputChars)) + "\n… [output truncated]"
        }
        return .success(toolCallId: "", toolName: name, result: output.isEmpty ? header : "\(header)\n\(output)")
    }

    // MARK: - Background

    /// Launch a long-lived command detached, redirecting its output to a temp log
    /// file (so a full pipe buffer can never block the server), observe it for a
    /// short grace window to capture startup output, then return with its pid and
    /// log path, leaving it running.
    private func runBackground(command: String, cwd: String?) async -> AgentToolResult {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("run_shell-\(UUID().uuidString).log")
        let logFD = open(logURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard logFD >= 0 else {
            return .error(toolCallId: "", toolName: name, message: "Failed to open background log file.")
        }
        setCloseOnExec(logFD)

        let pid: pid_t
        do {
            pid = try spawnInNewGroup(command: command, workingDirectory: cwd, stdoutFD: logFD)
        } catch {
            close(logFD)
            return .error(toolCallId: "", toolName: name, message: "Failed to launch shell: \(error.localizedDescription)")
        }
        close(logFD)                                  // child owns its dup'd copies

        try? await Task.sleep(nanoseconds: UInt64(backgroundGraceSeconds * 1_000_000_000))

        let early = readLogTail(logURL)
        if let status = reapIfExited(pid) {
            let header = "exit \(status.exitCode) (background command finished within \(Int(backgroundGraceSeconds))s)"
            return .success(toolCallId: "", toolName: name, result: early.isEmpty ? header : "\(header)\n\(early)")
        }

        var header = "started in background (pid \(pid)); still running. Full output: \(logURL.path)"
        if !early.isEmpty { header += "\n--- startup output ---\n\(early)" }
        return .success(toolCallId: "", toolName: name, result: header)
    }

    private func readLogTail(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        let text = decode(data)
        return text.count > maxOutputChars ? String(text.suffix(maxOutputChars)) + "\n… [truncated]" : text
    }

    // MARK: - Process group spawn (posix_spawn)

    /// Launch `/bin/zsh -lc <command>` as the leader of a **new process group**,
    /// with stdout+stderr wired to `stdoutFD` and stdin from /dev/null. Returns the
    /// child pid, which (being the group leader) equals the group id — so
    /// `kill(-pid, …)` signals the whole tree.
    private func spawnInNewGroup(command: String, workingDirectory: String?, stdoutFD: Int32) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, stdoutFD, 1)
        posix_spawn_file_actions_adddup2(&fileActions, stdoutFD, 2)
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addclose(&fileActions, stdoutFD)
        if let workingDirectory {
            posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // pgroup 0 → the child becomes leader of a brand-new group (pgid == pid).
        posix_spawnattr_setpgroup(&attr, 0)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))

        var pid: pid_t = 0
        let rc = withCStringArray(["/bin/zsh", "-lc", command]) { argv in
            posix_spawn(&pid, "/bin/zsh", &fileActions, &attr, argv, environ)
        }
        guard rc == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(rc),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(rc))])
        }
        return pid
    }

    /// SIGKILL the entire process group led by `pid`. Best-effort — a race where
    /// the group has already exited just returns ESRCH.
    private func killGroup(_ pid: pid_t) {
        kill(-pid, SIGKILL)
    }

    private struct ExitStatus { let exitCode: Int32 }

    /// Block until our direct child is reaped; grandchildren reparent to launchd
    /// and are reaped there. Returns its exit/signal code.
    private func reap(_ pid: pid_t) -> ExitStatus {
        var raw: Int32 = 0
        while waitpid(pid, &raw, 0) == -1 && errno == EINTR {}
        return ExitStatus(exitCode: decodeWaitStatus(raw))
    }

    /// Non-blocking reap: returns the status only if the child has already exited.
    private func reapIfExited(_ pid: pid_t) -> ExitStatus? {
        var raw: Int32 = 0
        let r = waitpid(pid, &raw, WNOHANG)
        guard r == pid else { return nil }
        return ExitStatus(exitCode: decodeWaitStatus(raw))
    }

    private func decodeWaitStatus(_ raw: Int32) -> Int32 {
        // WIFEXITED → exit code; otherwise 128 + signal, matching shell convention.
        if (raw & 0x7f) == 0 { return (raw >> 8) & 0xff }
        return 128 + (raw & 0x7f)
    }

    // MARK: - Helpers

    private enum StopReason { case finished, timedOut }

    private func decode(_ data: Data) -> String { String(data: data, encoding: .utf8) ?? "" }

    private func setCloseOnExec(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFD)
        if flags != -1 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
    }

    private func resolveWorkingDirectory(_ parameters: [String: Any]) -> String? {
        if let dir = (parameters["working_directory"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) {
            return expandPath(dir)
        }
        return defaultWorkingDirectory?.path
    }

    /// Commands that start a long-lived server and would otherwise block until the
    /// wall-clock timeout. Conservative: matches well-known dev-server invocations.
    static func looksLikeLongLivedServer(_ command: String) -> Bool {
        let c = command.lowercased()
        let markers = [
            "npm start", "npm run start", "npm run dev", "npm run serve",
            "yarn start", "yarn dev", "pnpm dev", "pnpm start",
            "ng serve", "vite", "next dev", "nuxt dev",
            "rails server", "rails s", "python -m http.server",
            "flask run", "uvicorn ", "gunicorn ",
        ]
        return markers.contains { c.contains($0) }
    }

    /// Build a null-terminated C string array for `posix_spawn`'s argv.
    private func withCStringArray<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var cStrings: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        cStrings.append(nil)
        defer { cStrings.forEach { free($0) } }
        return cStrings.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
#endif
