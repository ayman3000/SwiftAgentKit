//
//  BackgroundProcess.swift
//  SwiftAgentKitTools
//
//  Stopping a background launch from outside the tool that started it — a Stop
//  button in a UI, say. ShellTool spawns background commands in their own
//  process group precisely so the whole tree can be stopped together: `npm run
//  dev` is a shell that runs npm that runs node, and signalling only the pid we
//  know leaves the server holding the port.
//

import Foundation

public enum BackgroundProcess {

    /// Whether the process is running *and not already a zombie*.
    ///
    /// `kill(pid, 0)` alone is not enough: a child that has exited but has not
    /// been waited for still exists as a zombie and answers that probe, so a
    /// naive liveness check reports a stopped server as running forever. Reaping
    /// here is also what keeps zombies from piling up under a long-lived app.
    public static func isAlive(pid: Int32) -> Bool {
        var status: Int32 = 0
        // Our own child? Reap it if it has finished. ECHILD means it is not ours
        // (or already reaped), which is not evidence either way — fall through.
        if waitpid(pid, &status, WNOHANG) == pid { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Stop the whole process group: ask politely, then insist.
    ///
    /// SIGTERM first so a dev server can close its socket and clean up, then
    /// SIGKILL for anything that ignored it. Negative pid addresses the group,
    /// with a fall back to the single pid in case the group is gone.
    /// Returns true when nothing of it remains.
    @discardableResult
    public static func stop(pid: Int32, graceSeconds: Double = 2.0) async -> Bool {
        guard pid > 0 else { return true }
        signalGroup(pid, SIGTERM)

        // Poll rather than sleep the whole grace: a dev server usually dies in
        // well under a second, and the button should feel immediate.
        let deadline = Date().addingTimeInterval(graceSeconds)
        while Date() < deadline {
            if !isAlive(pid: pid) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        signalGroup(pid, SIGKILL)
        try? await Task.sleep(nanoseconds: 200_000_000)
        return !isAlive(pid: pid)
    }

    /// Signal the process group, falling back to the process itself.
    private static func signalGroup(_ pid: Int32, _ sig: Int32) {
        if kill(-pid, sig) != 0 { kill(pid, sig) }
    }
}
