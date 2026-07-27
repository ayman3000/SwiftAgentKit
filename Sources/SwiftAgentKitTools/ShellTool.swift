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

/// Run a shell command via `zsh` and return its combined stdout/stderr + exit code.
/// Always `requiresConfirmation` — the app must approve each invocation.
public struct ShellTool: AgentTool {
    public let name = "run_shell"
    public let description = """
    Run a shell command on this Mac via zsh and return its combined stdout/stderr \
    and exit code. Use for terminal tasks (listing files, git, build commands). \
    Every call must be approved by the user. Optionally set `working_directory`.
    """
    public let parameters = ToolParameters(
        properties: [
            "command": ToolParameterProperty(type: "string", description: "The shell command to run, e.g. `ls -la`."),
            "working_directory": ToolParameterProperty(type: "string", description: "Directory to run in (a leading ~ is expanded)."),
        ],
        required: ["command"]
    )

    public var requiresConfirmation: Bool { true }

    /// Directory used when the model doesn't specify `working_directory`. Apps can
    /// default this to the user's home for terminal-like behavior.
    private let defaultWorkingDirectory: URL?
    private let maxOutputChars: Int
    /// Wall-clock limit; a command exceeding it is terminated so a hung process
    /// (or one whose child keeps stdout open) never blocks the agent forever.
    private let timeoutSeconds: Double

    public init(defaultWorkingDirectory: URL? = nil, maxOutputChars: Int = 10_000, timeoutSeconds: Double = 120) {
        self.defaultWorkingDirectory = defaultWorkingDirectory
        self.maxOutputChars = maxOutputChars
        self.timeoutSeconds = timeoutSeconds
    }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let command = (parameters["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty
        else {
            return .error(toolCallId: "", toolName: name, message: "run_shell requires a non-empty `command`.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        if let dir = (parameters["working_directory"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) {
            process.currentDirectoryURL = URL(fileURLWithPath: expandPath(dir))
        } else if let defaultWorkingDirectory {
            process.currentDirectoryURL = defaultWorkingDirectory
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return .error(toolCallId: "", toolName: name, message: "Failed to launch shell: \(error.localizedDescription)")
        }

        // Read to EOF on a detached task (occurs when the process — and anything
        // holding its stdout — exits), raced against a wall-clock timeout that
        // terminates the process so the read unblocks.
        let handle = pipe.fileHandleForReading
        let readTask = Task.detached { handle.readDataToEndOfFile() }
        let timeoutTask = Task { [timeoutSeconds] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            if process.isRunning { process.terminate() }
        }
        let data = await readTask.value
        timeoutTask.cancel()
        process.waitUntilExit()
        // Our timeout terminates via SIGTERM → `.uncaughtSignal`; a normal exit is `.exit`.
        let timedOut = process.terminationReason == .uncaughtSignal

        var output = String(data: data, encoding: .utf8) ?? ""
        if output.count > maxOutputChars {
            output = String(output.prefix(maxOutputChars)) + "\n… [output truncated]"
        }
        var header = "exit \(process.terminationStatus)"
        if timedOut { header += " (terminated after \(Int(timeoutSeconds))s timeout)" }
        return .success(toolCallId: "", toolName: name, result: output.isEmpty ? header : "\(header)\n\(output)")
    }
}
#endif
