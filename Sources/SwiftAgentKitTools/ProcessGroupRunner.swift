//
//  ProcessGroupRunner.swift
//  SwiftAgentKitTools
//
//  Shared hardened subprocess runner: spawns the command as the leader of a new
//  process group and SIGKILLs the whole group on timeout or cancellation, so a
//  grandchild holding the stdout pipe can never block the read past the
//  deadline. Same technique ShellTool uses; extracted so PythonTool (and any
//  future tool) gets identical semantics.
//

#if os(macOS)
import Foundation
import Darwin

enum ProcessGroupRunner {

    struct Outcome {
        let exitCode: Int32
        let output: String
        let timedOut: Bool
    }

    /// Run `/bin/zsh -lc <command>` to completion with a wall-clock timeout.
    /// On timeout (or task cancellation) the entire process group is SIGKILLed,
    /// which closes the pipe and unblocks the read — partial output is returned.
    static func run(
        command: String,
        workingDirectory: String? = nil,
        timeoutSeconds: Double
    ) async -> Outcome {
        let pipe = Pipe()
        let writeFD = pipe.fileHandleForWriting.fileDescriptor
        setCloseOnExec(pipe.fileHandleForReading.fileDescriptor)
        setCloseOnExec(writeFD)

        let pid: pid_t
        do {
            pid = try spawnInNewGroup(command: command, workingDirectory: workingDirectory, stdoutFD: writeFD)
        } catch {
            return Outcome(exitCode: -1, output: "Failed to launch: \(error.localizedDescription)", timedOut: false)
        }
        try? pipe.fileHandleForWriting.close()

        let handle = pipe.fileHandleForReading
        let readTask = Task.detached { handle.readDataToEndOfFile() }

        enum Stop { case finished, timedOut }
        let stop: Stop = await withTaskCancellationHandler {
            await withTaskGroup(of: Stop.self) { group in
                group.addTask {
                    _ = await readTask.value
                    return .finished
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    return .timedOut
                }
                let first = await group.next() ?? .finished
                if first != .finished { kill(-pid, SIGKILL) }
                group.cancelAll()
                return first
            }
        } onCancel: {
            kill(-pid, SIGKILL)
        }

        let data = await readTask.value
        var raw: Int32 = 0
        while waitpid(pid, &raw, 0) == -1 && errno == EINTR {}
        let exitCode: Int32 = (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)

        return Outcome(
            exitCode: exitCode,
            output: String(data: data, encoding: .utf8) ?? "",
            timedOut: stop == .timedOut
        )
    }

    // MARK: - Spawn

    private static func spawnInNewGroup(
        command: String, workingDirectory: String?, stdoutFD: Int32
    ) throws -> pid_t {
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
        posix_spawnattr_setpgroup(&attr, 0)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))

        var pid: pid_t = 0
        let argv: [String] = ["/bin/zsh", "-lc", command]
        var cStrings: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cStrings.append(nil)
        defer { cStrings.forEach { free($0) } }
        let rc = cStrings.withUnsafeBufferPointer {
            posix_spawn(&pid, "/bin/zsh", &fileActions, &attr, $0.baseAddress!, environ)
        }
        guard rc == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(rc),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(rc))])
        }
        return pid
    }

    private static func setCloseOnExec(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFD)
        if flags != -1 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
    }
}
#endif
