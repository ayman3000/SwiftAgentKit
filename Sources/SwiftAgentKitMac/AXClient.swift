#if os(macOS)
import Foundation
@preconcurrency import ApplicationServices
import AppKit
import CoreGraphics

// ---------------------------------------------------------------------------
// MARK: - AXUIElement wrapper for Sendable boundary crossing
// ---------------------------------------------------------------------------
// AXUIElement is a CoreFoundation type and is NOT Sendable. We wrap it in an
// @unchecked Sendable box so we can store it in actor state and pass it over
// async boundaries without triggering Swift 6 strict-concurrency errors.
// All actual AX API calls happen inside the actor so the unsafety is bounded.

private final class AXElementBox: @unchecked Sendable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
}

// ---------------------------------------------------------------------------
// MARK: - Lock-based one-shot flag (no swift-atomics dependency)
// ---------------------------------------------------------------------------

private final class OneShotFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _resolved = false

    var isResolved: Bool {
        lock.lock(); defer { lock.unlock() }
        return _resolved
    }

    /// Returns true if this call "won" the race (i.e. was first to set the flag).
    func tryResolve() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if _resolved { return false }
        _resolved = true
        return true
    }
}

// ---------------------------------------------------------------------------
// MARK: - Key-code table helpers
// ---------------------------------------------------------------------------

private let keyNameToCode: [String: CGKeyCode] = [
    "return": 36, "enter": 76, "tab": 48, "space": 49, "delete": 51,
    "esc": 53, "escape": 53, "left": 123, "right": 124, "down": 125,
    "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
    "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
    "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
    "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
    "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
    "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
    "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
    "n": 45, "m": 46, ".": 47, "`": 50,
]

private func parseKeyCombo(_ keys: String) -> (keyCode: CGKeyCode, flags: CGEventFlags)? {
    let parts = keys.lowercased().split(separator: "+").map(String.init)
    guard let keyName = parts.last, let keyCode = keyNameToCode[keyName] else { return nil }
    var flags: CGEventFlags = []
    for mod in parts.dropLast() {
        switch mod {
        case "cmd", "command":       flags.insert(.maskCommand)
        case "shift":                flags.insert(.maskShift)
        case "opt", "option", "alt": flags.insert(.maskAlternate)
        case "ctrl", "control":      flags.insert(.maskControl)
        default: break
        }
    }
    return (keyCode, flags)
}

// ---------------------------------------------------------------------------
// MARK: - Frame extraction helpers
// ---------------------------------------------------------------------------
// kAXFrameAttribute does not exist in the public AX API.  Frame is computed
// from kAXPositionAttribute (CGPoint AXValue) + kAXSizeAttribute (CGSize AXValue).

private func axElementFrame(_ el: AXUIElement) -> CGRect {
    var posVal: CFTypeRef?
    var sizeVal: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posVal)
    AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeVal)
    var origin = CGPoint.zero
    var size   = CGSize.zero
    if let pv = posVal, CFGetTypeID(pv) == AXValueGetTypeID() {
        AXValueGetValue(pv as! AXValue, .cgPoint, &origin)
    }
    if let sv = sizeVal, CFGetTypeID(sv) == AXValueGetTypeID() {
        AXValueGetValue(sv as! AXValue, .cgSize, &size)
    }
    return CGRect(origin: origin, size: size)
}

// ---------------------------------------------------------------------------
// MARK: - AX value stringify helper
// ---------------------------------------------------------------------------

private func stringifyAXValue(_ raw: CFTypeRef?) -> String? {
    guard let raw else { return nil }
    if let s = raw as? String { return s.isEmpty ? nil : s }
    if let n = raw as? NSNumber { return n.stringValue }
    // Try AXValue sub-types: CGPoint / CGSize / CGRect
    if CFGetTypeID(raw) == AXValueGetTypeID() {
        let axVal = raw as! AXValue // force cast is safe: type ID confirmed
        var pt = CGPoint.zero
        var sz = CGSize.zero
        var rt = CGRect.zero
        if AXValueGetValue(axVal, .cgPoint, &pt) {
            return NSStringFromPoint(NSPoint(x: pt.x, y: pt.y))
        }
        if AXValueGetValue(axVal, .cgSize, &sz) {
            return NSStringFromSize(NSSize(width: sz.width, height: sz.height))
        }
        if AXValueGetValue(axVal, .cgRect, &rt) {
            return NSStringFromRect(NSRect(x: rt.origin.x, y: rt.origin.y,
                                          width: rt.size.width, height: rt.size.height))
        }
    }
    return nil
}

// ---------------------------------------------------------------------------
// MARK: - CGEvent helpers (nonisolated free functions)
// ---------------------------------------------------------------------------

private func postMouseClick(at point: CGPoint) {
    let src  = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                       mouseCursorPosition: point, mouseButton: .left)
    let up   = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                       mouseCursorPosition: point, mouseButton: .left)
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
}

private func postUnicodeText(_ text: String) {
    let src     = CGEventSource(stateID: .hidSystemState)
    let scalars = Array(text.unicodeScalars)
    var idx     = 0
    while idx < scalars.count {
        let batchEnd = min(idx + 20, scalars.count)
        let batch    = scalars[idx..<batchEnd].map { UniChar($0.value & 0xFFFF) }
        if let ev = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
            ev.keyboardSetUnicodeString(stringLength: batch.count, unicodeString: batch)
            ev.post(tap: .cghidEventTap)
        }
        if let ev = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
            ev.keyboardSetUnicodeString(stringLength: batch.count, unicodeString: batch)
            ev.post(tap: .cghidEventTap)
        }
        idx = batchEnd
    }
}

private func postKeyPress(keyCode: CGKeyCode, flags: CGEventFlags) {
    let src  = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
    let up   = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
    down?.flags = flags
    up?.flags   = flags
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
}

// ---------------------------------------------------------------------------
// MARK: - WaitState (Sendable shared state for waitFor)
// ---------------------------------------------------------------------------
// Holds everything the AXObserver C-callback needs to resume the continuation
// and the everything the timeout Task needs to cancel it.  Marked @unchecked
// Sendable because the continuation and client are only touched under the
// one-shot flag guarantee (exactly one of observer/timeout resumes it).
//
// The retained Unmanaged pointer is stored here so the C callback Task closure
// can call releaseRetained() without capturing an UnsafeMutableRawPointer
// directly, which would cause a Swift 6 "sending" error.

private final class WaitState: @unchecked Sendable {
    let continuation: CheckedContinuation<UITree, Error>
    let bundleId: String
    let target: MacTarget
    let forDisappearance: Bool
    let client: AXClient
    let flag = OneShotFlag()

    // Stores the Unmanaged reference we pass to AXObserver as refcon.
    // Set once before the observer is registered; released by the winner.
    private let lock = NSLock()
    private var _unmanagedSelf: Unmanaged<WaitState>?

    func setUnmanaged(_ u: Unmanaged<WaitState>) {
        lock.lock(); defer { lock.unlock() }
        _unmanagedSelf = u
    }

    /// Release the retained self-reference exactly once.
    func releaseRetained() {
        lock.lock()
        let u = _unmanagedSelf
        _unmanagedSelf = nil
        lock.unlock()
        u?.release()
    }

    init(
        continuation: CheckedContinuation<UITree, Error>,
        bundleId: String,
        target: MacTarget,
        forDisappearance: Bool,
        client: AXClient
    ) {
        self.continuation     = continuation
        self.bundleId         = bundleId
        self.target           = target
        self.forDisappearance = forDisappearance
        self.client           = client
    }
}

// ---------------------------------------------------------------------------
// MARK: - AXObserver C-callback (global function, context via refcon)
// ---------------------------------------------------------------------------

private let axObserverCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else { return }
    // takeUnretainedValue: we do NOT consume the retain here; releaseRetained() does.
    let state = Unmanaged<WaitState>.fromOpaque(refcon).takeUnretainedValue()
    guard !state.flag.isResolved else { return }

    // Cannot await inside a C callback; dispatch to an async Task.
    // Capture only `state` (WaitState is @unchecked Sendable) — no raw pointers.
    Task { [state] in
        if let snap = await state.client.snapshotAndCheck(
            bundleId: state.bundleId,
            target: state.target,
            forDisappearance: state.forDisappearance
        ) {
            if state.flag.tryResolve() {
                state.releaseRetained()
                state.continuation.resume(returning: snap)
            }
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - AXClient actor
// ---------------------------------------------------------------------------

public actor AXClient: AXDriving {

    // Per-call timeout hint (seconds). Kept for future use / documentation;
    // not yet applied to individual AX attribute reads (those are typically fast
    // but can hang on buggy apps — a future improvement can wrap them in a Task).
    private let callTimeout: Double

    // Monotonic generation counter; bumped on each snapshot call.
    private var generation: Int = 0

    // Ref cache: maps "e1", "e2", … → AXElementBox for the *current* generation.
    // Cleared at the start of each snapshot so stale refs are detected.
    private var refCache: [String: AXElementBox] = [:]
    private var currentGeneration: Int = 0

    public init(callTimeout: Double = 2.0) {
        self.callTimeout = callTimeout
    }

    // -------------------------------------------------------------------------
    // MARK: isTrusted (nonisolated — no actor state needed)
    // -------------------------------------------------------------------------

    public nonisolated func isTrusted() -> Bool { AXPermission.isTrusted() }

    // -------------------------------------------------------------------------
    // MARK: snapshot
    // -------------------------------------------------------------------------

    public func snapshot(bundleId: String) async throws -> UITree {
        try checkTrust()
        let pid = try resolvePid(bundleId: bundleId)

        generation += 1
        let gen = generation
        refCache = [:]
        currentGeneration = gen

        var nodeCount = 0
        var capHit    = false
        var counter   = 0

        let appElement = AXUIElementCreateApplication(pid)

        // Recursive tree walk — all AX calls happen synchronously here, inside
        // the actor, so no concurrency issues with the AXUIElement handles.
        func walk(_ el: AXUIElement, depth: Int) -> UINode {
            counter += 1
            let refStr = "e\(counter)"
            refCache[refStr] = AXElementBox(el)

            // role
            var roleVal: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleVal)
            let role = (roleVal as? String) ?? "unknown"

            // title (fallback to kAXDescriptionAttribute)
            var titleVal: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &titleVal)
            var title = titleVal as? String
            if title == nil || title!.isEmpty {
                var descVal: CFTypeRef?
                AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descVal)
                title = descVal as? String
            }
            if let t = title, t.isEmpty { title = nil }

            // identifier
            var idVal: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXIdentifierAttribute as CFString, &idVal)
            let identifier = idVal as? String

            // value (stringify)
            var valueAttr: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &valueAttr)
            let value: String? = stringifyAXValue(valueAttr)

            // frame (position + size — kAXFrameAttribute does not exist)
            let frame = axElementFrame(el)

            // isEnabled
            var enabledVal: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXEnabledAttribute as CFString, &enabledVal)
            let isEnabled = (enabledVal as? Bool) ?? true

            // actions
            var actionsVal: CFArray?
            AXUIElementCopyActionNames(el, &actionsVal)
            let actions = (actionsVal as? [String]) ?? []

            // children (depth-cap 60 / node-cap 2000)
            var childrenNodes: [UINode] = []
            if depth < 60 && nodeCount < 2000 {
                var childrenVal: CFTypeRef?
                let childErr = AXUIElementCopyAttributeValue(
                    el, kAXChildrenAttribute as CFString, &childrenVal)
                if childErr == .success, let children = childrenVal as? [AXUIElement] {
                    for child in children {
                        if nodeCount >= 2000 { capHit = true; break }
                        nodeCount += 1
                        childrenNodes.append(walk(child, depth: depth + 1))
                    }
                }
            } else if nodeCount >= 2000 {
                capHit = true
            }

            return UINode(ref: refStr, role: role, title: title, identifier: identifier,
                          value: value, frame: frame, isEnabled: isEnabled,
                          actions: actions, children: childrenNodes)
        }

        nodeCount = 1
        var root = walk(appElement, depth: 0)

        if capHit {
            let note = "[node cap 2000 hit — tree truncated]"
            root = UINode(ref: root.ref, role: root.role,
                          title: (root.title.map { $0 + " " } ?? "") + note,
                          identifier: root.identifier, value: root.value,
                          frame: root.frame, isEnabled: root.isEnabled,
                          actions: root.actions, children: root.children)
        }

        return UITree(generation: gen, bundleId: bundleId, root: root)
    }

    // -------------------------------------------------------------------------
    // MARK: click
    // -------------------------------------------------------------------------

    public func click(bundleId: String, target: MacTarget) async throws {
        try checkTrust()
        try resolvePid(bundleId: bundleId)

        let (el, node) = try await resolveElement(target: target, bundleId: bundleId)

        if node.actions.contains(kAXPressAction as String) {
            let result = AXUIElementPerformAction(el, kAXPressAction as CFString)
            if result != .success {
                throw MacDriverError(code: "ax_error",
                                     message: "AXPress failed: \(result.rawValue)")
            }
        } else {
            let center = CGPoint(x: node.frame.midX, y: node.frame.midY)
            postMouseClick(at: center)
        }
    }

    // -------------------------------------------------------------------------
    // MARK: type
    // -------------------------------------------------------------------------

    public func type(bundleId: String, text: String, target: MacTarget?) async throws {
        try checkTrust()
        try resolvePid(bundleId: bundleId)

        if let target {
            let (el, node) = try await resolveElement(target: target, bundleId: bundleId)
            if node.actions.contains(kAXPressAction as String) {
                AXUIElementPerformAction(el, kAXPressAction as CFString)
            } else {
                AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString,
                                             true as CFBoolean)
            }
            try await Task.sleep(nanoseconds: 50_000_000) // 50 ms for focus to settle
        }

        postUnicodeText(text)
    }

    // -------------------------------------------------------------------------
    // MARK: key
    // -------------------------------------------------------------------------

    public func key(bundleId: String, keys: String) async throws {
        try checkTrust()
        try resolvePid(bundleId: bundleId)

        guard let (keyCode, flags) = parseKeyCombo(keys) else {
            throw MacDriverError(code: "bad_key",
                                 message: "Cannot parse key combo: \(keys)")
        }
        postKeyPress(keyCode: keyCode, flags: flags)
    }

    // -------------------------------------------------------------------------
    // MARK: waitFor
    // -------------------------------------------------------------------------

    public func waitFor(
        bundleId: String,
        target: MacTarget,
        timeoutSeconds: Double,
        forDisappearance: Bool
    ) async throws -> UITree {
        try checkTrust()
        let pid = try resolvePid(bundleId: bundleId)

        // Fast path: predicate already satisfied before we register the observer.
        let initialSnapshot = try await snapshot(bundleId: bundleId)
        if predicateSatisfied(snapshot: initialSnapshot, target: target,
                              forDisappearance: forDisappearance) {
            return initialSnapshot
        }

        // Bridge AXObserver + RunLoop to Swift async via a CheckedContinuation.
        return try await withCheckedThrowingContinuation { continuation in
            let state    = WaitState(continuation: continuation, bundleId: bundleId,
                                     target: target, forDisappearance: forDisappearance,
                                     client: self)
            let statePtr = Unmanaged.passRetained(state)
            // Store the unmanaged pointer inside state so the C callback can
            // release it without capturing a raw UnsafeMutableRawPointer.
            state.setUnmanaged(statePtr)

            var observer: AXObserver?
            let createErr = AXObserverCreate(pid, axObserverCallback, &observer)
            guard createErr == .success, let obs = observer else {
                state.releaseRetained()
                continuation.resume(throwing: MacDriverError(
                    code: "ax_error",
                    message: "AXObserverCreate failed: \(createErr.rawValue)"))
                return
            }

            let appElement    = AXUIElementCreateApplication(pid)
            let notifications = [kAXValueChangedNotification,
                                 kAXCreatedNotification,
                                 kAXFocusedUIElementChangedNotification]
            for note in notifications {
                AXObserverAddNotification(obs, appElement, note as CFString,
                                         statePtr.toOpaque())
            }

            // Run the observer on a private thread so it doesn't block the actor.
            let observerBox = AXObserverBox(obs)
            let thread = Thread { [state] in
                let rl = RunLoop.current
                CFRunLoopAddSource(rl.getCFRunLoop(),
                                   AXObserverGetRunLoopSource(observerBox.observer),
                                   .defaultMode)
                while !state.flag.isResolved {
                    rl.run(until: Date(timeIntervalSinceNow: 0.1))
                }
            }
            thread.start()

            // Timeout task.
            Task { [state] in
                try? await Task.sleep(
                    nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if state.flag.tryResolve() {
                    state.releaseRetained()
                    let snap = try? await self.snapshot(bundleId: bundleId)
                    continuation.resume(throwing: MacDriverError(
                        code: "timeout",
                        message: "waitFor timed out after \(timeoutSeconds)s",
                        tree: snap))
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // MARK: launch / runningApps
    // -------------------------------------------------------------------------

    public func launch(bundleId: String) async throws {
        try await AppResolver.launch(bundleId: bundleId)
    }

    public nonisolated func runningApps() -> [(name: String, bundleId: String)] {
        AppResolver.runningApps()
    }

    // -------------------------------------------------------------------------
    // MARK: Internal helpers (actor-isolated)
    // -------------------------------------------------------------------------

    @discardableResult
    private func resolvePid(bundleId: String) throws -> pid_t {
        guard let pid = AppResolver.pid(forBundleId: bundleId) else {
            throw MacDriverError(code: "not_running",
                                 message: "\(bundleId) is not running")
        }
        return pid
    }

    private func checkTrust() throws {
        guard AXPermission.isTrusted() else {
            throw MacDriverError(code: "not_trusted",
                                 message: "Accessibility access not granted")
        }
    }

    /// Resolve a MacTarget to its live AXUIElement + a lightweight UINode.
    ///
    /// Strategy:
    /// 1. If ref + generation provided and match the current generation → cache hit.
    /// 2. Otherwise take a fresh snapshot and search depth-first by title/identifier/ref.
    private func resolveElement(
        target: MacTarget,
        bundleId: String
    ) async throws -> (AXUIElement, UINode) {
        // Cache lookup by ref + generation.
        if let ref = target.ref, let targetGen = target.generation {
            guard targetGen == currentGeneration else {
                throw MacDriverError(code: "stale_ref",
                                     message: "Ref \(ref) is from generation \(targetGen), current is \(currentGeneration)")
            }
            if let box = refCache[ref] {
                let el      = box.element
                let frame   = axElementFrame(el)
                var actArr: CFArray?
                AXUIElementCopyActionNames(el, &actArr)
                let actions = (actArr as? [String]) ?? []
                let node    = UINode(ref: ref, role: "", title: nil, identifier: nil,
                                     value: nil, frame: frame, isEnabled: true,
                                     actions: actions, children: [])
                return (el, node)
            }
            throw MacDriverError(code: "stale_ref",
                                 message: "Ref \(ref) not found in cache")
        }

        // Fresh snapshot + depth-first search.
        let snap = try await snapshot(bundleId: bundleId)
        if let (el, node) = findInSnapshot(snap.root, target: target) {
            return (el, node)
        }
        throw MacDriverError(code: "not_found",
                             message: "No element matching \(target)",
                             tree: snap)
    }

    /// Depth-first search returning (AXUIElement, UINode) when target matches.
    private func findInSnapshot(
        _ node: UINode,
        target: MacTarget
    ) -> (AXUIElement, UINode)? {
        let titleMatch = target.title.map      { node.title      == $0 } ?? true
        let idMatch    = target.identifier.map { node.identifier == $0 } ?? true
        let refMatch   = target.ref.map        { node.ref        == $0 } ?? true
        if titleMatch && idMatch && refMatch, let box = refCache[node.ref] {
            return (box.element, node)
        }
        for child in node.children {
            if let found = findInSnapshot(child, target: target) { return found }
        }
        return nil
    }

    /// True when the snapshot satisfies the wait predicate.
    func predicateSatisfied(
        snapshot: UITree,
        target: MacTarget,
        forDisappearance: Bool
    ) -> Bool {
        let found = findInSnapshot(snapshot.root, target: target) != nil
        return forDisappearance ? !found : found
    }

    /// Called from the AXObserver callback; returns a snapshot if the predicate is met.
    func snapshotAndCheck(
        bundleId: String,
        target: MacTarget,
        forDisappearance: Bool
    ) async -> UITree? {
        guard let snap = try? await snapshot(bundleId: bundleId) else { return nil }
        return predicateSatisfied(snapshot: snap, target: target,
                                  forDisappearance: forDisappearance) ? snap : nil
    }
}

// ---------------------------------------------------------------------------
// MARK: - AXObserver box (avoids Sendable warning for AXObserver)
// ---------------------------------------------------------------------------
// AXObserver is not Sendable in the SDK headers.  We box it @unchecked so it
// can cross into the Thread closure; we only read it (GetRunLoopSource) and
// never mutate it after the Thread starts.

private final class AXObserverBox: @unchecked Sendable {
    let observer: AXObserver
    init(_ observer: AXObserver) { self.observer = observer }
}

#endif
