import XCTest
import Network
import Foundation

/// The driver's single "test": start an HTTP server and serve until idle-timeout.
/// Launched by the host via `xcodebuild test-without-building`; it is NOT a test of anything.
final class DriverMain: XCTestCase {
    func testRunServerForever() throws {
        let port = UInt16(ProcessInfo.processInfo.environment["SIM_DRIVER_PORT"] ?? "8722") ?? 8722
        let server = DriverServer(port: port)
        try server.start()
        // Idle timeout: exit if no request for 10 minutes so orphaned drivers don't linger.
        while Date().timeIntervalSince(server.lastActivity) < 600 {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
    }
}

/// Minimal HTTP/1.1 server: one request per connection, Content-Length bodies only.
final class DriverServer {
    private let listener: NWListener
    private let routes = DriverRoutes()
    private let activityLock = NSLock()
    private var _lastActivity = Date()
    var lastActivity: Date {
        activityLock.lock(); defer { activityLock.unlock() }
        return _lastActivity
    }
    private func touchActivity() {
        activityLock.lock(); defer { activityLock.unlock() }
        _lastActivity = Date()
    }
    private let queue = DispatchQueue(label: "sim-driver")

    init(port: UInt16) {
        listener = try! NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
    }

    func start() throws {
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: self?.queue ?? .global())
            self?.receive(conn, buffer: Data())
        }
        listener.start(queue: queue)
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self, error == nil, let data else { conn.cancel(); return }
            var buf = buffer; buf.append(data)
            if let request = HTTPRequest(parsing: buf) {
                self.touchActivity()
                let response = self.routes.handle(request)   // synchronous: XCUITest calls must stay on this thread
                conn.send(content: response.serialized(), completion: .contentProcessed { _ in conn.cancel() })
            } else if done {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)   // need more bytes (body not complete yet)
            }
        }
    }
}

struct HTTPRequest {
    var method: String; var path: String; var query: [String: String]; var body: Data

    /// Returns nil until the full head + Content-Length body has arrived.
    init?(parsing data: Data) {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<headEnd.lowerBound], as: UTF8.self)
        let lines = head.split(separator: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        method = String(parts[0])
        let urlParts = parts[1].split(separator: "?", maxSplits: 1)
        path = String(urlParts[0])
        query = [:]
        if urlParts.count == 2 {
            for pair in urlParts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    query[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                }
            }
        }
        let contentLength = lines.compactMap { line -> Int? in
            let lower = line.lowercased()
            guard lower.hasPrefix("content-length:") else { return nil }
            return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        let bodyStart = headEnd.upperBound
        guard data.count - bodyStart >= contentLength else { return nil }
        body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
    }
}

struct HTTPResponse {
    var status: Int; var contentType: String; var body: Data
    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "application/json",
                     body: (try? JSONEncoder().encode(value)) ?? Data("{}".utf8))
    }
    static func png(_ data: Data) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "image/png", body: data)
    }
    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"; case 400: return "Bad Request"; case 404: return "Not Found"
        case 408: return "Request Timeout"; case 409: return "Conflict"; default: return "Error"
        }
    }
    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(body); return out
    }
}
