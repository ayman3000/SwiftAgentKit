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
}
#endif
