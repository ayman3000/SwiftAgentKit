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
    running and the tool returns immediately with its pid and any startup output. \
    Foreground commands are killed after `timeout_seconds` (default 120); for \
    builds and test suites pass a larger `timeout_seconds` (up to 900).
    """
    public let parameters = ToolParameters(
        properties: [
            "command": ToolParameterProperty(type: "string", description: "The shell command to run, e.g. `ls -la`."),
            "working_directory": ToolParameterProperty(type: "string", description: "Directory to run in (a leading ~ is expanded)."),
            "background": ToolParameterProperty(type: "boolean", description: "Run detached for long-lived servers; returns immediately with the pid instead of waiting for exit."),
            "timeout_seconds": ToolParameterProperty(type: "integer", description: "Seconds to allow before the command is killed. Default 120; up to 900 for builds and test suites."),
        ],
        required: ["command"]
    )

    public var inputExamples: [String] { [
        #"""
        {"command": "swift test 2>&1 | tail -40", "working_directory": "~/proj/kit", "timeout_seconds": 600}
        """#,
        #"""
        {"command": "npm run dev", "working_directory": "~/proj/site", "background": true}
        """#
    ] }

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
    /// Upper bound for a per-call `timeout_seconds` override.
    public static let maxTimeoutSeconds = 900

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
        let timeout = Self.effectiveTimeout(parameters["timeout_seconds"], default: timeoutSeconds)

        return background
            ? await runBackground(command: command, cwd: cwd)
            : await runForeground(command: command, cwd: cwd, timeoutSeconds: timeout)
    }

    /// Per-call `timeout_seconds` (clamped to 1...`maxTimeoutSeconds`) or the
    /// instance default when absent/unparseable. Not used for `background` runs.
    static func effectiveTimeout(_ raw: Any?, default defaultSeconds: Double) -> Double {
        guard let requested = intValue(raw) else { return defaultSeconds }
        return Double(min(max(requested, 1), maxTimeoutSeconds))
    }

    // MARK: - Foreground

    /// Run until the shell exits, capturing output via a pipe. The shell's exit
    /// is raced against the wall-clock timeout and cooperative task
    /// cancellation; a timeout or Stop SIGKILLs the whole process group.
    ///
    /// The run ends when zsh exits, not when the pipe closes: a child the
    /// command backgrounded itself (`python3 -m http.server 8080 &`) keeps the
    /// write end open for as long as it lives. Waiting for that EOF held the
    /// agent for the full timeout and then killed the server it had just
    /// started. Such children are left running; their later output is drained
    /// and dropped.
    private func runForeground(command: String, cwd: String?, timeoutSeconds: Double) async -> AgentToolResult {
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

        // Read with a dispatch readability handler, not a blocking read on the
        // cooperative pool (that starved the timeout timer on 3-core CI runners).
        let collector = PipeCollector(pipe.fileHandleForReading, keepBytes: maxOutputChars * 4)
        let exit = Task { await reap(pid) }

        let stop: StopReason = await withTaskCancellationHandler {
            await withTaskGroup(of: StopReason.self) { group in
                group.addTask {
                    _ = await exit.value              // the shell exited on its own
                    return .finished
                }
                group.addTask { [timeoutSeconds] in
                    try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    return .timedOut
                }
                let first = await group.next() ?? .finished
                // Kill BEFORE draining the group: the exit child awaits a
                // non-cancellable waitpid, which only returns once the shell dies.
                if first != .finished { killGroup(pid) }
                group.cancelAll()
                return first
            }
        } onCancel: {
            killGroup(pid)                            // Stop button → kill immediately
        }

        let status = await exit.value
        let cancelled = Task.isCancelled
        // Output written just before the shell exited may still be in flight.
        // A clean exit gets a short drain; past it, whatever still holds the
        // pipe is a background child and is left running.
        // (A cancelled task's sleep returns at once, so that wait stays short.)
        let closed = await collector.waitForEOF(seconds: stop == .timedOut ? 2 : 0.3)
        var output = decode(collector.take())

        let header: String
        if cancelled {
            header = "stopped by user"
        } else if stop == .timedOut {
            header = "exit \(status.exitCode). Killed after \(Int(timeoutSeconds)) s (run_shell timeout). "
                + "The output below is everything captured before the kill — the command may or may not "
                + "have finished its work. For builds and test suites pass timeout_seconds (up to "
                + "\(Self.maxTimeoutSeconds)), or use background: true for servers."
        } else if !closed {
            header = "exit \(status.exitCode). Processes this command started in the background are still "
                + "running; their later output is not captured (redirect it to a file to keep it)."
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
        try ProcessGroupRunner.spawnInNewGroup(command: command, workingDirectory: workingDirectory, stdoutFD: stdoutFD)
    }

    /// SIGKILL the entire process group led by `pid`. Best-effort — a race where
    /// the group has already exited just returns ESRCH. If the child did not end
    /// up leading its own group, kill it directly rather than nothing.
    private func killGroup(_ pid: pid_t) {
        if kill(-pid, SIGKILL) != 0 { kill(pid, SIGKILL) }
    }

    private struct ExitStatus { let exitCode: Int32 }

    /// Block until our direct child is reaped; grandchildren reparent to launchd
    /// and are reaped there. Returns its exit/signal code.
    private func reap(_ pid: pid_t) async -> ExitStatus {
        let raw: Int32 = await BlockingWork.run {
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) == -1 && errno == EINTR {}
            return raw
        }
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

    /// Lossy: a byte cap can split a multi-byte character, and one bad byte
    /// must not blank the whole output.
    private func decode(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

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
            "rails server", "rails s", "python -m http.server", "python3 -m http.server",
            "flask run", "uvicorn ", "gunicorn ",
        ]
        return markers.contains { c.contains($0) }
    }

}

/// Collects a pipe's output from a dispatch readability handler until EOF.
/// After `take()` it keeps draining (so a background writer never blocks on a
/// full pipe) but stops storing.
final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var storing = true
    private var closed = false
    private let keepBytes: Int
    /// Held until EOF: a deallocated FileHandle closes the read end, and a
    /// background server then dies of SIGPIPE on its next log line.
    private var handle: FileHandle?

    init(_ handle: FileHandle, keepBytes: Int) {
        self.keepBytes = keepBytes
        self.handle = handle
        handle.readabilityHandler = { [self] h in
            let chunk = h.availableData
            lock.lock(); defer { lock.unlock() }
            if chunk.isEmpty {
                h.readabilityHandler = nil            // EOF; also breaks the retain cycle
                try? h.close()
                self.handle = nil
                closed = true
            } else if storing, data.count < keepBytes {
                data.append(chunk.prefix(keepBytes - data.count))
            }
        }
    }

    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    /// True once the pipe reached EOF, false if `seconds` passed first.
    func waitForEOF(seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !isClosed {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    /// What was collected so far; later output is drained and dropped.
    func take() -> Data {
        lock.lock(); defer { lock.unlock() }
        storing = false
        return data
    }
}
#endif
