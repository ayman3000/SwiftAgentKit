#if os(macOS)
import Foundation

// MARK: - SimDriving protocol

public protocol SimDriving: Sendable {
    func snapshot(bundleId: String) async throws -> UITree
    func tap(bundleId: String, target: SimWire.Target, longPress: Bool) async throws
    func type(bundleId: String, text: String, target: SimWire.Target?) async throws
    func swipe(bundleId: String, direction: String, target: SimWire.Target?) async throws
    func pressHome() async throws
    func rotate(bundleId: String, orientation: String) async throws -> UITree
    func waitFor(bundleId: String, target: SimWire.Target, timeoutSeconds: Double, forDisappearance: Bool) async throws -> UITree
    func alert(accept: Bool) async throws
    func launch(bundleId: String, terminateFirst: Bool) async throws
    func terminate(bundleId: String) async throws
    func screenshot() async throws -> Data
}

// MARK: - SimDriverError

public struct SimDriverError: Error, LocalizedError, Sendable {
    public var code: String
    public var message: String
    public var tree: UITree?
    public var errorDescription: String? { "\(code): \(message)" }

    public init(code: String, message: String, tree: UITree? = nil) {
        self.code = code; self.message = message; self.tree = tree
    }
}

// MARK: - SimClient

public actor SimClient: SimDriving {
    private let baseURL: URL
    private let session: URLSession
    /// Relaunches the driver (production: `SimDriverManager.launch`, which
    /// health-checks and replaces a dead session). nil = no recovery possible.
    private let relaunch: (@Sendable () async throws -> Void)?

    /// Driver relaunches allowed over this client's lifetime. Each relaunch
    /// costs seconds (health wait) — the bound stops a broken environment
    /// (e.g. a simulator that can't host the driver) from rebuild-looping
    /// while still surviving the routine idle-exit/dead-session cases.
    public static let maxRelaunchesPerClient = 3
    private var relaunchesRemaining = SimClient.maxRelaunchesPerClient

    public init(manager: SimDriverManager, udid: String, runtime: String) async {
        // manager.port is a nonisolated let in Swift 6.2 — no await needed.
        self.baseURL = URL(string: "http://127.0.0.1:\(manager.port)")!
        self.relaunch = { try await manager.launch(udid: udid, runtime: runtime) }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 120   // /wait can legitimately take a while
        self.session = URLSession(configuration: cfg)
    }

    /// Test-only: point at a stub server, with an optional relaunch hook.
    /// Uses a short-timeout session so a misbehaving stub fails fast instead of hanging.
    init(baseURL: URL, relaunch: (@Sendable () async throws -> Void)? = nil) {
        self.baseURL = baseURL
        self.relaunch = relaunch
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: cfg)
    }

    // MARK: SimDriving

    public func snapshot(bundleId: String) async throws -> UITree {
        try await get("/tree", query: ["bundleId": bundleId], as: SimWire.TreeResponse.self).tree
    }

    public func tap(bundleId: String, target: SimWire.Target, longPress: Bool) async throws {
        _ = try await post("/tap",
                           SimWire.TapRequest(bundleId: bundleId, target: target, longPress: longPress),
                           as: SimWire.OKResponse.self)
    }

    public func type(bundleId: String, text: String, target: SimWire.Target?) async throws {
        _ = try await post("/type",
                           SimWire.TypeRequest(bundleId: bundleId, text: text, target: target),
                           as: SimWire.OKResponse.self)
    }

    public func swipe(bundleId: String, direction: String, target: SimWire.Target?) async throws {
        _ = try await post("/swipe",
                           SimWire.SwipeRequest(bundleId: bundleId, direction: direction, target: target),
                           as: SimWire.OKResponse.self)
    }

    public func rotate(bundleId: String, orientation: String) async throws -> UITree {
        try await post("/rotate",
                       SimWire.RotateRequest(bundleId: bundleId, orientation: orientation),
                       as: SimWire.TreeResponse.self).tree
    }

    public func pressHome() async throws {
        _ = try await post("/press",
                           SimWire.PressRequest(button: "home"),
                           as: SimWire.OKResponse.self)
    }

    public func waitFor(bundleId: String, target: SimWire.Target, timeoutSeconds: Double,
                        forDisappearance: Bool) async throws -> UITree {
        // Waiting only observes — safe to retry after a driver relaunch.
        try await post("/wait",
                       SimWire.WaitRequest(bundleId: bundleId, target: target,
                                           timeoutSeconds: timeoutSeconds,
                                           forDisappearance: forDisappearance),
                       as: SimWire.TreeResponse.self, idempotent: true).tree
    }

    public func alert(accept: Bool) async throws {
        _ = try await post("/alert",
                           SimWire.AlertRequest(accept: accept),
                           as: SimWire.OKResponse.self)
    }

    public func launch(bundleId: String, terminateFirst: Bool) async throws {
        _ = try await post("/launch",
                           SimWire.LaunchRequest(bundleId: bundleId, terminateFirst: terminateFirst),
                           as: SimWire.OKResponse.self)
    }

    public func terminate(bundleId: String) async throws {
        _ = try await post("/terminate",
                           SimWire.LaunchRequest(bundleId: bundleId, terminateFirst: false),
                           as: SimWire.OKResponse.self)
    }

    public func screenshot() async throws -> Data {
        try await rawData(request(path: "/screenshot", query: [:]))
    }

    // MARK: Transport helpers

    private func get<T: Decodable>(_ path: String, query: [String: String], as type: T.Type) async throws -> T {
        try await decode(await rawData(request(path: path, query: query), idempotent: true))
    }

    private func post<B: Encodable, T: Decodable>(_ path: String, _ body: B, as type: T.Type,
                                                  idempotent: Bool = false) async throws -> T {
        var req = request(path: path, query: [:])
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        return try await decode(await rawData(req, idempotent: idempotent))
    }

    private func request(path: String, query: [String: String]) -> URLRequest {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return URLRequest(url: comps.url!)
    }

    /// The driver responded, but its XCUITest automation session is broken —
    /// only a fresh test-without-building run fixes it. Observed live as
    /// `Error getting main window kAXErrorServerNotFound` (Code=8) after the
    /// in-simulator server's automation session died mid-run.
    private func isSessionFatal(_ error: SimDriverError) -> Bool {
        error.message.contains("kAXErrorServerNotFound")
    }

    private func consumeRelaunchBudget() -> Bool {
        guard relaunch != nil, relaunchesRemaining > 0 else { return false }
        relaunchesRemaining -= 1
        return true
    }

    /// Execute `req`, relaunching the driver (bounded per client) and retrying
    /// once when recovery is safe:
    /// - TRANSPORT failure: the request never arrived → safe to retry ANY
    ///   endpoint. This is the driver's idle-exit / dead-server case.
    /// - SESSION-FATAL driver error (`isSessionFatal`): the server answered but
    ///   its automation session is dead. `idempotent` requests (tree reads,
    ///   screenshots, waits) retry after relaunch; actions (tap/type/…) surface
    ///   the error — re-POSTing could double-fire them.
    /// Ordinary driver errors (stale ref, wait timeout) are the driver WORKING
    /// and always surface unchanged.
    private func rawData(_ req: URLRequest, idempotent: Bool = true) async throws -> Data {
        do {
            return try await send(req)
        } catch let e as SimDriverError {
            guard isSessionFatal(e), idempotent, consumeRelaunchBudget() else { throw e }
            try await relaunch?()
            return try await send(req)
        } catch {
            guard consumeRelaunchBudget() else { throw error }
            try await relaunch?()
            return try await send(req)
        }
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if let err = try? JSONDecoder().decode(SimWire.ErrorResponse.self, from: data) {
                throw SimDriverError(code: err.code, message: err.message, tree: err.tree)
            }
            throw SimDriverError(code: "http_\(status)",
                                  message: String(decoding: data, as: UTF8.self),
                                  tree: nil)
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }
}
#endif
