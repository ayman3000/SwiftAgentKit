import XCTest
import Foundation

final class DriverRoutes {
    private var apps: [String: XCUIApplication] = [:]
    private var generation = 0
    private var refFrames: [String: CGRect] = [:]   // refs of the CURRENT generation only

    func handle(_ req: HTTPRequest) -> HTTPResponse {
        do {
            switch (req.method, req.path) {
            case ("GET", "/health"):  return .json(SimWire.OKResponse())
            case ("GET", "/tree"):
                guard let bundleId = req.query["bundleId"] else {
                    return .json(SimWire.ErrorResponse(code: "bad_request", message: "bundleId query param required"), status: 400)
                }
                return .json(SimWire.TreeResponse(tree: try snapshot(bundleId: bundleId)))
            case ("GET", "/screenshot"):
                return .png(XCUIScreen.main.screenshot().pngRepresentation)
            case ("POST", "/tap"):
                let r = try decode(SimWire.TapRequest.self, req)
                let coord = try resolveCoordinate(r.target, bundleId: r.bundleId)
                r.longPress ? coord.press(forDuration: 1.2) : coord.tap()
                return .json(SimWire.OKResponse())
            case ("POST", "/type"):
                let r = try decode(SimWire.TypeRequest.self, req)
                if let target = r.target { try resolveCoordinate(target, bundleId: r.bundleId).tap() }
                app(r.bundleId).typeText(r.text)
                return .json(SimWire.OKResponse())
            case ("POST", "/swipe"):
                let r = try decode(SimWire.SwipeRequest.self, req)
                let el: XCUIElement = r.target.flatMap { try? resolveElement($0, bundleId: r.bundleId) } ?? app(r.bundleId)
                switch r.direction {
                case "up": el.swipeUp(); case "down": el.swipeDown()
                case "left": el.swipeLeft(); case "right": el.swipeRight()
                default: return .json(SimWire.ErrorResponse(code: "bad_request", message: "direction must be up/down/left/right"), status: 400)
                }
                return .json(SimWire.OKResponse())
            case ("POST", "/press"):
                let r = try decode(SimWire.PressRequest.self, req)
                guard r.button == "home" else {
                    return .json(SimWire.ErrorResponse(code: "bad_request", message: "only button=home supported"), status: 400)
                }
                XCUIDevice.shared.press(.home)
                return .json(SimWire.OKResponse())
            case ("POST", "/wait"):
                let r = try decode(SimWire.WaitRequest.self, req)
                let el = try resolveElement(r.target, bundleId: r.bundleId, allowMissing: true)
                let ok = r.forDisappearance
                    ? el.waitForNonExistence(timeout: r.timeoutSeconds)
                    : el.waitForExistence(timeout: r.timeoutSeconds)
                if ok { return .json(SimWire.TreeResponse(tree: try snapshot(bundleId: r.bundleId))) }
                return .json(SimWire.ErrorResponse(code: "timeout",
                    message: "condition not met within \(r.timeoutSeconds)s",
                    tree: try? snapshot(bundleId: r.bundleId)), status: 408)
            case ("POST", "/alert"):
                let r = try decode(SimWire.AlertRequest.self, req)
                let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                let alert = springboard.alerts.firstMatch
                guard alert.waitForExistence(timeout: 2) else {
                    return .json(SimWire.ErrorResponse(code: "not_found", message: "no alert on screen"), status: 404)
                }
                let buttons = alert.buttons
                (r.accept ? buttons.element(boundBy: buttons.count - 1) : buttons.element(boundBy: 0)).tap()
                return .json(SimWire.OKResponse())
            case ("POST", "/launch"):
                let r = try decode(SimWire.LaunchRequest.self, req)
                let a = app(r.bundleId)
                if r.terminateFirst { a.terminate() }
                a.launch()
                return .json(SimWire.OKResponse())
            case ("POST", "/terminate"):
                let r = try decode(SimWire.LaunchRequest.self, req)
                app(r.bundleId).terminate()
                return .json(SimWire.OKResponse())
            default:
                return .json(SimWire.ErrorResponse(code: "not_found", message: "no route \(req.method) \(req.path)"), status: 404)
            }
        } catch let e as RouteError {
            return .json(e.response, status: e.status)
        } catch {
            return .json(SimWire.ErrorResponse(code: "internal", message: "\(error)"), status: 500)
        }
    }

    private struct RouteError: Error { var status: Int; var response: SimWire.ErrorResponse }

    private func decode<T: Decodable>(_ type: T.Type, _ req: HTTPRequest) throws -> T {
        do { return try JSONDecoder().decode(type, from: req.body) }
        catch { throw RouteError(status: 400, response: .init(code: "bad_request", message: "body decode failed: \(error)")) }
    }

    private func app(_ bundleId: String) -> XCUIApplication {
        if let a = apps[bundleId] { return a }
        let a = XCUIApplication(bundleIdentifier: bundleId)
        apps[bundleId] = a
        return a
    }

    private func snapshot(bundleId: String) throws -> UITree {
        generation += 1
        refFrames.removeAll()
        var counter = 0
        func convert(_ snap: XCUIElementSnapshot) -> UINode {
            counter += 1
            let ref = "e\(counter)"
            refFrames[ref] = snap.frame
            return UINode(
                ref: ref,
                type: String(describing: snap.elementType),
                label: snap.label.isEmpty ? nil : snap.label,
                identifier: snap.identifier.isEmpty ? nil : snap.identifier,
                value: (snap.value as? String).flatMap { $0.isEmpty ? nil : $0 },
                frame: snap.frame,
                isHittable: snap.frame.width > 0 && snap.frame.height > 0,
                isEnabled: snap.isEnabled,
                children: snap.children.map(convert))
        }
        let root = convert(try app(bundleId).snapshot())
        return UITree(generation: generation, bundleId: bundleId, root: root)
    }

    private func resolveCoordinate(_ target: SimWire.Target, bundleId: String) throws -> XCUICoordinate {
        if let ref = target.ref {
            guard target.generation == generation, let frame = refFrames[ref] else {
                throw RouteError(status: 409, response: .init(code: "stale_ref",
                    message: "ref \(ref) is from an old snapshot — call sim_ui again and use fresh refs"))
            }
            let a = app(bundleId)
            let normalized = CGVector(dx: frame.midX / a.frame.width, dy: frame.midY / a.frame.height)
            return a.coordinate(withNormalizedOffset: normalized)
        }
        let el = try resolveElement(target, bundleId: bundleId)
        return el.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }

    private func resolveElement(_ target: SimWire.Target, bundleId: String, allowMissing: Bool = false) throws -> XCUIElement {
        var predicates: [NSPredicate] = []
        if let l = target.label { predicates.append(NSPredicate(format: "label == %@", l)) }
        if let i = target.identifier { predicates.append(NSPredicate(format: "identifier == %@", i)) }
        guard !predicates.isEmpty else {
            throw RouteError(status: 400, response: .init(code: "bad_request",
                message: "target needs ref, label, or identifier"))
        }
        let pred = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
        let el = app(bundleId).descendants(matching: .any).matching(pred).firstMatch
        if !allowMissing && !el.exists {
            throw RouteError(status: 404, response: .init(code: "not_found",
                message: "no element matching \(target)", tree: try? snapshot(bundleId: bundleId)))
        }
        return el
    }
}
