//
//  PythonTool.swift
//  SwiftAgentKitTools
//
//  Run Python in an isolated virtual environment. Encapsulates venv creation and
//  package installation so on-device Python is a first-class capability rather
//  than something the model has to orchestrate via raw shell commands.
//  macOS-only (`Process` + venv).
//

#if os(macOS)
import Foundation
import SwiftAgentKit

/// Runs Python 3 code in a dedicated virtual environment and returns its combined
/// stdout/stderr + exit code. Ensures the venv exists and pip-installs any
/// requested packages first (isolated from system Python). `requiresConfirmation`
/// — running code is as powerful as the shell.
public struct PythonTool: AgentTool {
    public let name = "run_python"
    public let description = """
    Run Python 3 code in an isolated virtual environment and return its combined \
    stdout/stderr and exit code. Put the full script in `code`. List any \
    third-party `packages` you import (e.g. numpy, pandas, matplotlib, fpdf2) — \
    they are pip-installed into the environment first. Prefer this over run_shell \
    for Python. Every call must be approved.
    """
    public let parameters = ToolParameters(
        properties: [
            "code": ToolParameterProperty(type: "string", description: "The Python 3 source to run."),
            "packages": ToolParameterProperty(
                type: "array",
                description: "Third-party pip packages to ensure are installed before running.",
                itemsType: "string"),
        ],
        required: ["code"]
    )

    public var requiresConfirmation: Bool { true }

    private let venvPath: URL
    private let timeoutSeconds: Double
    private let maxOutputChars: Int

    /// - Parameter venvPath: where the virtual environment lives (created if
    ///   missing). Apps typically point this at a per-app location.
    public init(venvPath: URL, timeoutSeconds: Double = 180, maxOutputChars: Int = 10_000) {
        self.venvPath = venvPath
        self.timeoutSeconds = timeoutSeconds
        self.maxOutputChars = maxOutputChars
    }

    private var pythonPath: String { venvPath.appendingPathComponent("bin/python3").path }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard let code = (parameters["code"] as? String), !code.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "run_python requires `code`.")
        }
        let packages = stringArray(parameters["packages"])

        // 1. Ensure the venv exists.
        if !FileManager.default.isExecutableFile(atPath: pythonPath) {
            _ = await runCommand("python3 -m venv \(quote(venvPath.path))")
            if !FileManager.default.isExecutableFile(atPath: pythonPath) {
                return .error(toolCallId: "", toolName: name,
                              message: "Could not create a Python venv at \(venvPath.path). Is python3 installed?")
            }
        }

        // 2. Ensure requested packages (one pip call; fast when already satisfied).
        if !packages.isEmpty {
            let install = await runCommand(
                "\(quote(pythonPath)) -m pip install --quiet \(packages.map(quote).joined(separator: " "))")
            if install.exitCode != 0 {
                return .error(toolCallId: "", toolName: name,
                              message: "pip install failed (exit \(install.exitCode)):\n\(install.output)")
            }
        }

        // 3. Stage the code to a temp file and run it with the venv python.
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sak-python-\(UUID().uuidString).py")
        do {
            try code.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            return .error(toolCallId: "", toolName: name, message: "Failed to stage script: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let run = await runCommand("\(quote(pythonPath)) \(quote(scriptURL.path))")
        var output = run.output
        if output.count > maxOutputChars {
            output = String(output.prefix(maxOutputChars)) + "\n… [output truncated]"
        }
        var header = "exit \(run.exitCode)"
        if run.timedOut { header += " (terminated after \(Int(timeoutSeconds))s timeout)" }
        return .success(toolCallId: "", toolName: name, result: output.isEmpty ? header : "\(header)\n\(output)")
    }

    // MARK: - Private

    /// Run a command via a login shell (so PATH resolves python3), reading to EOF
    /// on a detached task raced against a wall-clock timeout (no pipe deadlock).
    private func runCommand(_ command: String) async -> (exitCode: Int32, output: String, timedOut: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "Failed to launch: \(error.localizedDescription)", false)
        }
        let handle = pipe.fileHandleForReading
        let readTask = Task.detached { handle.readDataToEndOfFile() }
        let timeoutTask = Task { [timeoutSeconds] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            if process.isRunning { process.terminate() }
        }
        let data = await readTask.value
        timeoutTask.cancel()
        process.waitUntilExit()
        let timedOut = process.terminationReason == .uncaughtSignal
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "", timedOut)
    }

    /// Single-quote a shell argument safely.
    private func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
#endif
