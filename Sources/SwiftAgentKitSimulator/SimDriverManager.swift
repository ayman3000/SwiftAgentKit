#if os(macOS)
import Foundation

/// Holds a Process and terminates it when deallocated.
/// Used so SimDriverManager (which targets macOS 13+) can guarantee port cleanup
/// without requiring `isolated deinit` (available only from macOS 15.4).
private final class ChildBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
    deinit { process.terminate() }
}

public actor SimDriverManager {
    public let port: UInt16
    // Stored as ChildBox so that if the actor is dropped without an explicit
    // shutdown() call, the box's deinit terminates the child process and
    // releases the port.
    private var childBox: ChildBox?
    private var child: Process? { childBox?.process }

    public init(port: UInt16 = 8722) { self.port = port }

    public var isRunning: Bool { child?.isRunning ?? false }

    /// Bump whenever anything under Resources/SimDriverProject changes.
    /// v2 = loopback-only bind in DriverMain.swift.
    /// v3 = ref taps resolve back to the live element (element-anchored tap) in DriverRoutes.swift.
    static let driverSourceVersion = 4

    public static func cacheDirectory(xcodeVersion: String, runtime: String) -> URL {
        let shortRuntime = runtime.replacingOccurrences(
            of: "com.apple.CoreSimulator.SimRuntime.", with: "")
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftAgentKitSimulator")
            .appendingPathComponent("\(xcodeVersion)-\(shortRuntime)-v\(driverSourceVersion)")
    }

    static func xcodeVersion() async throws -> String {
        let (status, out) = try await Simctl.run(["xcodebuild", "-version"], timeout: 30)
        guard status == 0, let firstLine = out.split(separator: "\n").first else {
            throw SimctlError.commandFailed("xcodebuild -version failed: \(out)")
        }
        // Parse "Xcode 16.0 (Build 16A242d)" → "16.0"
        let tokens = firstLine.split(separator: " ")
        guard let xcodeIdx = tokens.firstIndex(of: "Xcode"),
              tokens.index(after: xcodeIdx) < tokens.endIndex else {
            throw SimctlError.commandFailed("xcodebuild -version output unrecognised: \(firstLine)")
        }
        let version = String(tokens[tokens.index(after: xcodeIdx)])
        guard !version.isEmpty else {
            throw SimctlError.commandFailed("xcodebuild -version produced empty version string")
        }
        return version   // e.g. "16.0" or "26.1"
    }

    /// Copy the resource project into the cache dir (resources are read-only) and
    /// build-for-testing once. Returns the .xctestrun path.
    public func ensureBuilt(udid: String, runtime: String) async throws -> URL {
        let xcode = try await Self.xcodeVersion()
        let dir = Self.cacheDirectory(xcodeVersion: xcode, runtime: runtime)
        let fm = FileManager.default

        // Return a cached build if one exists. ANY failure to locate an xctestrun
        // (missing dir, empty products, partial build) means we must rebuild from scratch.
        if let existing = try? findXCTestRun(in: dir) { return existing }

        try? fm.removeItem(at: dir)   // remove stale/partial build if present
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let src = Bundle.module.url(forResource: "SimDriverProject", withExtension: nil) else {
            throw SimctlError.commandFailed("SimDriverProject resource missing from bundle")
        }
        let proj = dir.appendingPathComponent("SimDriverProject")
        try fm.copyItem(at: src, to: proj)

        let (status, out) = try await Simctl.run([
            "xcodebuild", "build-for-testing",
            "-project", proj.appendingPathComponent("SimDriver.xcodeproj").path,
            "-scheme", "SimDriver",
            "-destination", "id=\(udid)",
            "-derivedDataPath", dir.appendingPathComponent("DerivedData").path,
            "CODE_SIGNING_ALLOWED=NO",
        ], timeout: 600)
        guard status == 0 else {
            throw SimctlError.commandFailed("driver build failed:\n\(out.suffix(4000))")
        }
        return try findXCTestRun(in: dir)
    }

    private func findXCTestRun(in dir: URL) throws -> URL {
        let products = dir.appendingPathComponent("DerivedData/Build/Products")
        let files = (try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)) ?? []
        guard let run = files.first(where: { $0.pathExtension == "xctestrun" }) else {
            throw SimctlError.commandFailed("no .xctestrun in \(products.path)")
        }
        return run
    }

    public func launch(udid: String, runtime: String) async throws {
        guard !isRunning else { return }
        let xctestrun = try await ensureBuilt(udid: udid, runtime: runtime)
        try injectPort(into: xctestrun)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["xcodebuild", "test-without-building",
                       "-xctestrun", xctestrun.path,
                       "-destination", "id=\(udid)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        childBox = ChildBox(p)

        try await waitForHealth(timeout: 90)
    }

    /// Set SIM_DRIVER_PORT in every test configuration's TestingEnvironmentVariables.
    private func injectPort(into xctestrun: URL) throws {
        let data = try Data(contentsOf: xctestrun)
        let raw = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard var plist = raw as? [String: Any] else {
            throw SimctlError.commandFailed("xctestrun plist root is not a dictionary")
        }
        for (key, value) in plist {
            guard var config = value as? [String: Any] else { continue }
            var env = (config["TestingEnvironmentVariables"] as? [String: String]) ?? [:]
            env["SIM_DRIVER_PORT"] = String(port)
            config["TestingEnvironmentVariables"] = env
            plist[key] = config
        }
        let out = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try out.write(to: xctestrun)
    }

    private func waitForHealth(timeout: Double) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        while Date() < deadline {
            // Fast-fail: if the child exited before becoming healthy, don't burn the full timeout.
            if child?.isRunning == false {
                shutdownNow()
                throw SimctlError.commandFailed("SimDriver process exited before becoming healthy")
            }
            if let (_, resp) = try? await URLSession.shared.data(from: url),
               (resp as? HTTPURLResponse)?.statusCode == 200 { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        shutdownNow()
        throw SimctlError.commandFailed("SimDriver did not become healthy within \(timeout)s")
    }

    public func shutdown() { shutdownNow() }
    private func shutdownNow() { childBox?.process.terminate(); childBox = nil }
}
#endif
