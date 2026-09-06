#if os(macOS)
import XCTest
import Network
import Foundation
@testable import SwiftAgentKitSimulator

// MARK: - Minimal HTTP/1.1 stub server backed by NWListener (~60 lines)

/// A scripted list of (path, statusCode, body) triples.  Excess requests → 500.
final class StubHTTPServer: @unchecked Sendable {
    struct Scenario {
        let path: String
        let status: Int
        let body: Data
    }

    private let listener: NWListener
    let port: UInt16
    private let scenarios: [Scenario]
    private let lock = NSLock()
    private var idx = 0

    /// Single-phase init: wires ALL handlers (including newConnectionHandler) before start(),
    /// then waits for .ready.  This eliminates the race where a connection arrives between
    /// start() and newConnectionHandler being set (which caused the original hang).
    static func make(scenarios: [Scenario]) throws -> StubHTTPServer {
        let listener = try NWListener(using: .tcp, on: 0)
        let server = StubHTTPServer(listener: listener, scenarios: scenarios)

        let sem = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { sem.signal() }
        }
        // newConnectionHandler must be set BEFORE start() so no connections are dropped.
        listener.newConnectionHandler = { [weak server] conn in server?.handle(conn) }
        listener.start(queue: .global())
        sem.wait()

        return server
    }

    private init(listener: NWListener, scenarios: [Scenario]) {
        self.listener = listener
        self.port = 0   // placeholder; real port is read after .ready (see portNumber below)
        self.scenarios = scenarios
    }

    var portNumber: UInt16 { listener.port?.rawValue ?? 0 }

    func stop() { listener.cancel() }

    private func nextScenario(for path: String) -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        for i in idx..<scenarios.count where scenarios[i].path == path {
            idx = i + 1
            return (scenarios[i].status, scenarios[i].body)
        }
        return (500, Data("no scenario for \(path)".utf8))
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data else { conn.cancel(); return }
            let raw = String(data: data, encoding: .utf8) ?? ""
            // Parse first request line: "METHOD /path?q HTTP/1.1\r\n…"
            let path = raw.split(separator: "\n").first.flatMap { line -> String? in
                let tokens = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
                guard tokens.count >= 2 else { return nil }
                return String(tokens[1]).components(separatedBy: "?").first
            } ?? "/"
            let (status, body) = self.nextScenario(for: path)
            let header = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var resp = Data(header.utf8); resp.append(body)
            conn.send(content: resp, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}

// MARK: - Helpers

private func makeTree(generation: Int = 42) -> UITree {
    UITree(generation: generation, bundleId: "com.example.App",
           root: UINode(ref: "r0", type: "Application", label: nil, identifier: nil,
                        value: nil, frame: .zero, isHittable: false, isEnabled: true, children: []))
}

private func encode<T: Encodable>(_ value: T) -> Data {
    try! JSONEncoder().encode(value)
}

// MARK: - SimClientTests

final class SimClientTests: XCTestCase {

    // Stub returns TreeResponse; assert tree.generation
    func testSnapshotDecodesTree() async throws {
        let tree = makeTree(generation: 7)
        let server = try StubHTTPServer.make(scenarios: [
            .init(path: "/tree", status: 200, body: encode(SimWire.TreeResponse(tree: tree))),
        ])
        defer { server.stop() }

        let client = SimClient(baseURL: URL(string: "http://127.0.0.1:\(server.portNumber)")!)
        let got = try await client.snapshot(bundleId: "com.example.App")
        XCTAssertEqual(got.generation, 7)
        XCTAssertEqual(got.bundleId, "com.example.App")
    }

    // Stub returns 408 ErrorResponse{code:"timeout", tree:…}; assert error.tree != nil
    func testWaitTimeoutThrowsSimDriverErrorWithTree() async throws {
        let tree = makeTree(generation: 99)
        let errorPayload = encode(SimWire.ErrorResponse(code: "timeout",
                                                         message: "timed out waiting for element",
                                                         tree: tree))
        let server = try StubHTTPServer.make(scenarios: [
            .init(path: "/wait", status: 408, body: errorPayload),
        ])
        defer { server.stop() }

        let client = SimClient(baseURL: URL(string: "http://127.0.0.1:\(server.portNumber)")!)
        do {
            _ = try await client.waitFor(bundleId: "com.example.App",
                                         target: SimWire.Target(label: "OK"),
                                         timeoutSeconds: 5,
                                         forDisappearance: false)
            XCTFail("Expected SimDriverError to be thrown")
        } catch let error as SimDriverError {
            XCTAssertEqual(error.code, "timeout")
            XCTAssertNotNil(error.tree, "tree should be propagated on timeout")
            XCTAssertEqual(error.tree?.generation, 99)
        }
    }

    // Stub returns 409 stale_ref; assert error.code == "stale_ref"
    func testStaleRefSurfacesCode() async throws {
        let errorPayload = encode(SimWire.ErrorResponse(code: "stale_ref",
                                                         message: "ref belongs to an older generation",
                                                         tree: nil))
        let server = try StubHTTPServer.make(scenarios: [
            .init(path: "/tap", status: 409, body: errorPayload),
        ])
        defer { server.stop() }

        let client = SimClient(baseURL: URL(string: "http://127.0.0.1:\(server.portNumber)")!)
        do {
            try await client.tap(bundleId: "com.example.App",
                                 target: SimWire.Target(ref: "r0", generation: 1),
                                 longPress: false)
            XCTFail("Expected SimDriverError to be thrown")
        } catch let error as SimDriverError {
            XCTAssertEqual(error.code, "stale_ref")
            XCTAssertNil(error.tree)
        }
    }

    // MARK: - Reconnect policy
    // Live failure mode (Quakely run, 2026-08-29): the in-simulator driver dies
    // (10-min idle exit / broken automation session) while the host-side
    // xcodebuild wrapper lingers, so every later sim_* call fails. The client
    // must relaunch the driver — bounded — and retry safe requests.

    /// Thread-safe relaunch-call counter usable as the client's relaunch hook.
    private final class RelaunchSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
        func bump() { lock.lock(); defer { lock.unlock() }; _count += 1 }
    }

    private func axDisabledBody() -> Data {
        encode(SimWire.ErrorResponse(
            code: "internal",
            message: "Error Domain=com.apple.dt.xctest.automation-support.error Code=... \"Error getting main window kAXErrorAPIDisabled\"",
            tree: nil))
    }

    // A headless device (no Simulator window) answers kAXErrorAPIDisabled and
    // executed nothing → reveal the window and retry once, even for an action.
    func testWindowMissingRevealsWindowAndRetriesAnyCall() async throws {
        let server = try StubHTTPServer.make(scenarios: [
            .init(path: "/tap", status: 500, body: axDisabledBody()),
            .init(path: "/tap", status: 200, body: encode(SimWire.OKResponse(ok: true))),
        ])
        defer { server.stop() }
        let relaunches = RelaunchSpy(), reveals = RelaunchSpy()
        let client = SimClient(baseURL: URL(string: "http://127.0.0.1:\(server.portNumber)")!,
                               relaunch: { relaunches.bump() }, revealWindow: { reveals.bump() })
        try await client.tap(bundleId: "com.example.App",
                             target: SimWire.Target(ref: "r0", generation: 1), longPress: false)
        XCTAssertEqual(reveals.count, 1)
        XCTAssertEqual(relaunches.count, 0)
    }

    // Only one reveal per client: if the window still doesn't help, surface the
    // error with the human hint instead of looping.
    func testWindowMissingSurfacesHintAfterOneReveal() async throws {
        let server = try StubHTTPServer.make(scenarios: [
            .init(path: "/tree", status: 500, body: axDisabledBody()),
            .init(path: "/tree", status: 500, body: axDisabledBody()),
        ])
        defer { server.stop() }
        let reveals = RelaunchSpy()
        let client = SimClient(baseURL: URL(string: "http://127.0.0.1:\(server.portNumber)")!,
                               revealWindow: { reveals.bump() })
        do {
            _ = try await client.snapshot(bundleId: "com.example.App")
            XCTFail("Expected SimDriverError")
        } catch let error as SimDriverError {
            XCTAssertTrue(error.errorDescription?.contains("no visible window") == true)
        }
        XCTAssertEqual(reveals.count, 1)
    }

    private func fatalErrorBody() -> Data {
        encode(SimWire.ErrorResponse(
            code: "internal",
            message: "Error Domain=com.apple.dt.xctest.automation-support.error Code=8 \"Error getting main window kAXErrorServerNotFound\"",
            tree: nil))
    }

    // A session-fatal driver error (kAXErrorServerNotFound) on an IDEMPOTENT
    // call → relaunch once and retry; the retried call succeeds.
    func testSessionFatalErrorRelaunchesAndRetriesIdempotentCall() async throws {
        let tree = makeTree(generation: 9)
        let server = try StubHTTPServer.make(scenarios: [
            .init(path: "/tree", status: 500, body: fatalErrorBody()),
            .init(path: "/tree", status: 200, body: encode(SimWire.TreeResponse(tree: tree))),
        ])
        defer { server.stop() }
        let spy = RelaunchSpy()
        let client = SimClient(baseURL: URL(string: "http://127.0.0.1:\(server.portNumber)")!,
                               relaunch: { spy.bump() })
        let result = try await client.snapshot(bundleId: "com.example.App")
        XCTAssertEqual(result.generation, 9)
        XCTAssertEqual(spy.count, 1)
    }

    // The same session-fatal error on a NON-idempotent call (tap) must surface
    // without relaunch — re-POSTing an action could double-fire it.
    func testSessionFatalErrorDoesNotRetryNonIdempotentCall() async throws {
        let server = try StubHTTPServer.make(scenarios: [
            .init(path: "/tap", status: 500, body: fatalErrorBody()),
        ])
        defer { server.stop() }
        let spy = RelaunchSpy()
        let client = SimClient(baseURL: URL(string: "http://127.0.0.1:\(server.portNumber)")!,
                               relaunch: { spy.bump() })
        do {
            try await client.tap(bundleId: "com.example.App",
                                 target: SimWire.Target(ref: "r0", generation: 1), longPress: false)
            XCTFail("Expected SimDriverError")
        } catch let error as SimDriverError {
            XCTAssertTrue(error.message.contains("kAXErrorServerNotFound"))
        }
        XCTAssertEqual(spy.count, 0)
    }

    // An ordinary driver error (stale ref, wait timeout, …) is the driver
    // WORKING — never relaunch for those.
    func testOrdinaryDriverErrorDoesNotRelaunch() async throws {
        let server = try StubHTTPServer.make(scenarios: [
            .init(path: "/tree", status: 409,
                  body: encode(SimWire.ErrorResponse(code: "stale_ref", message: "ref r9 is stale", tree: nil))),
        ])
        defer { server.stop() }
        let spy = RelaunchSpy()
        let client = SimClient(baseURL: URL(string: "http://127.0.0.1:\(server.portNumber)")!,
                               relaunch: { spy.bump() })
        do {
            _ = try await client.snapshot(bundleId: "com.example.App")
            XCTFail("Expected SimDriverError")
        } catch let error as SimDriverError {
            XCTAssertEqual(error.code, "stale_ref")
        }
        XCTAssertEqual(spy.count, 0)
    }

    // Transport failure (nothing listening) → relaunch and retry, ANY endpoint
    // (a connect failure means the request never arrived, so re-POST is safe).
    // The relaunch budget is bounded per client: after it's spent, transport
    // failures surface immediately with no further relaunch attempts.
    func testTransportFailureRelaunchBudgetIsBounded() async throws {
        // Port from a listener we immediately stop — nothing is listening.
        let dead = try StubHTTPServer.make(scenarios: [])
        let port = dead.portNumber
        dead.stop()
        let spy = RelaunchSpy()
        let client = SimClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!,
                               relaunch: { spy.bump() })
        for _ in 0..<(SimClient.maxRelaunchesPerClient + 2) {
            do {
                _ = try await client.snapshot(bundleId: "com.example.App")
                XCTFail("Expected transport error")
            } catch is SimDriverError {
                XCTFail("Expected a transport error, not a driver error")
            } catch {
                // expected: URLError connection failure
            }
        }
        XCTAssertEqual(spy.count, SimClient.maxRelaunchesPerClient)
    }
}
#endif
