#if os(macOS)
import Foundation

public enum SimctlError: Error, LocalizedError {
    case commandFailed(String)
    public var errorDescription: String? {
        if case .commandFailed(let m) = self { return m }
        return nil
    }
}

public enum Simctl {
    public struct SimDevice: Codable, Sendable, Equatable {
        public var udid: String
        public var name: String
        public var state: String
        public var runtime: String
        public var isBooted: Bool { state == "Booted" }
    }

    private struct DeviceListJSON: Decodable {
        struct Entry: Decodable { var udid: String; var name: String; var state: String }
        var devices: [String: [Entry]]
    }

    public static func parseDevices(json: Data) throws -> [SimDevice] {
        let list = try JSONDecoder().decode(DeviceListJSON.self, from: json)
        return list.devices.flatMap { runtime, entries in
            entries.map { SimDevice(udid: $0.udid, name: $0.name, state: $0.state, runtime: runtime) }
        }.sorted { $0.name < $1.name }
    }

    public static func listDevices() async throws -> [SimDevice] {
        let (status, out) = try await run(["simctl", "list", "devices", "--json", "available"], timeout: 30)
        guard status == 0, let data = out.data(using: .utf8) else {
            throw SimctlError.commandFailed("simctl list failed: \(out)")
        }
        return try parseDevices(json: data)
    }

    public static func bootedDevice() async throws -> SimDevice? {
        try await listDevices().first { $0.isBooted }
    }

    public static func boot(udid: String) async throws {
        let (status, out) = try await run(["simctl", "boot", udid], timeout: 120)
        // "Unable to boot device in current state: Booted" is fine.
        guard status == 0 || out.contains("current state: Booted") else {
            throw SimctlError.commandFailed("simctl boot failed: \(out)")
        }
        let (bsStatus, bsOut) = try await run(["simctl", "bootstatus", udid], timeout: 180)  // wait until usable
        guard bsStatus == 0 else { throw SimctlError.commandFailed("simctl bootstatus failed: \(bsOut)") }
    }

    public static func install(udid: String, appPath: String) async throws {
        let (status, out) = try await run(["simctl", "install", udid, appPath], timeout: 120)
        guard status == 0 else { throw SimctlError.commandFailed("simctl install failed: \(out)") }
    }

    public static func launchApp(udid: String, bundleId: String) async throws {
        let (status, out) = try await run(["simctl", "launch", udid, bundleId], timeout: 60)
        guard status == 0 else { throw SimctlError.commandFailed("simctl launch failed: \(out)") }
    }

    public static func terminateApp(udid: String, bundleId: String) async throws {
        _ = try await run(["simctl", "terminate", udid, bundleId], timeout: 30)  // non-zero if not running: fine
    }

    /// Short-lived `xcrun` invocation with combined output. Not for long-running work.
    static func run(_ args: [String], timeout: Double) async throws -> (status: Int32, output: String) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe; p.standardError = pipe
                do { try p.run() } catch { cont.resume(throwing: error); return }
                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                // Note: if a command emits > pipe-buffer output before the timeout fires,
                // the read blocks until the process dies; fine for short simctl commands.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timer.cancel()
                cont.resume(returning: (p.terminationStatus, String(data: data, encoding: .utf8) ?? ""))
            }
        }
    }
}
#endif
