#if os(macOS)
import Foundation

public actor SimDriverManager {
    public let port: UInt16
    private var child: Process?

    public init(port: UInt16 = 8722) { self.port = port }

    public var isRunning: Bool { child?.isRunning ?? false }

    public static func cacheDirectory(xcodeVersion: String, runtime: String) -> URL {
        let shortRuntime = runtime.replacingOccurrences(
            of: "com.apple.CoreSimulator.SimRuntime.", with: "")
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftAgentKitSimulator")
            .appendingPathComponent("\(xcodeVersion)-\(shortRuntime)")
    }

    static func xcodeVersion() async throws -> String {
        let (status, out) = try await Simctl.run(["xcodebuild", "-version"], timeout: 30)
        guard status == 0, let line = out.split(separator: "\n").first else {
            throw SimctlError.commandFailed("xcodebuild -version failed: \(out)")
        }
        return line.replacingOccurrences(of: "Xcode ", with: "")   // "26.1"
    }

    /// Copy the resource project into the cache dir (resources are read-only) and
    /// build-for-testing once. Returns the .xctestrun path.
    public func ensureBuilt(udid: String, runtime: String) async throws -> URL {
        let xcode = try await Self.xcodeVersion()
        let dir = Self.cacheDirectory(xcodeVersion: xcode, runtime: runtime)
        let fm = FileManager.default
        if let existing = try? findXCTestRun(in: dir) { return existing }

        try? fm.removeItem(at: dir)   // stale partial build
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
        child = p

        try await waitForHealth(timeout: 90)
    }

    /// Set SIM_DRIVER_PORT in every test configuration's TestingEnvironmentVariables.
    private func injectPort(into xctestrun: URL) throws {
        let data = try Data(contentsOf: xctestrun)
        var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
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
            if let (_, resp) = try? await URLSession.shared.data(from: url),
               (resp as? HTTPURLResponse)?.statusCode == 200 { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        shutdownNow()
        throw SimctlError.commandFailed("SimDriver did not become healthy within \(timeout)s")
    }

    public func shutdown() { shutdownNow() }
    private func shutdownNow() { child?.terminate(); child = nil }
}
#endif
