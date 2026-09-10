#if os(macOS)
import Foundation
@preconcurrency import ApplicationServices
import AppKit
import CoreGraphics
import ScreenCaptureKit

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
    "return": 36, "enter": 76, "tab": 48, "space": 49, "delete": 51, "fwddelete": 117,
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

/// Spellings models use for keys the table names differently.
let keyAliases: [String: String] = [
    "backspace": "delete", "del": "delete", "forwarddelete": "fwddelete",
    "arrowleft": "left", "arrowright": "right", "arrowup": "up", "arrowdown": "down",
    "leftarrow": "left", "rightarrow": "right", "uparrow": "up", "downarrow": "down",
    "spacebar": "space", "ret": "return", "newline": "return",
    "pgup": "pageup", "pgdn": "pagedown", "pgdown": "pagedown",
]

func parseKeyCombo(_ keys: String) -> (keyCode: CGKeyCode, flags: CGEventFlags)? {
    let parts = keys.lowercased().replacingOccurrences(of: " ", with: "")
        .split(separator: "+").map(String.init)
    guard let rawName = parts.last else { return nil }
    let keyName = keyAliases[rawName] ?? rawName
    guard let keyCode = keyNameToCode[keyName] else { return nil }
    var flags: CGEventFlags = []
    for mod in parts.dropLast() {
        switch mod {
        case "cmd", "command", "meta", "super": flags.insert(.maskCommand)
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
    // Rich text views (Notes, TextEdit) hand back attributed strings.
    if let a = raw as? NSAttributedString { return a.string.isEmpty ? nil : a.string }
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

private func postMouseClick(at point: CGPoint, clicks: Int = 1, right: Bool = false) {
    let src  = CGEventSource(stateID: .hidSystemState)
    let button: CGMouseButton = right ? .right : .left
    let downType: CGEventType = right ? .rightMouseDown : .leftMouseDown
    let upType: CGEventType   = right ? .rightMouseUp : .leftMouseUp
    // Move first: many views only accept a click where the pointer already is.
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
    usleep(50_000)
    for n in 1...max(1, clicks) {
        let down = CGEvent(mouseEventSource: src, mouseType: downType, mouseCursorPosition: point, mouseButton: button)
        let up   = CGEvent(mouseEventSource: src, mouseType: upType, mouseCursorPosition: point, mouseButton: button)
        down?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
        up?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
        down?.post(tap: .cghidEventTap)
        usleep(30_000)
        up?.post(tap: .cghidEventTap)
        if n < clicks { usleep(90_000) }
    }
}

/// Types text. Newlines and tabs are sent as real Return/Tab key presses: a
/// control character inside a unicode key event is handled as the key and the
/// characters after it in the same event are dropped ("\nBye" typed only "\n").
private func postUnicodeText(_ text: String) {
    var run = ""
    func flush() { if !run.isEmpty { postUnicodeRun(run); run = "" } }
    for ch in text {
        switch ch {
        case "\n", "\r", "\r\n": flush(); postKeyPress(keyCode: 36, flags: []); usleep(20_000)
        case "\t":                flush(); postKeyPress(keyCode: 48, flags: []); usleep(20_000)
        default:                  run.append(ch)
        }
    }
    flush()
}

private func postUnicodeRun(_ text: String) {
    let src    = CGEventSource(stateID: .hidSystemState)
    // Build batches from UTF-16 code units (UniChar == UInt16).
    // Using unicodeScalars and masking with 0xFFFF truncates supplementary-plane
    // code points (emoji, etc.) instead of encoding them as surrogate pairs.
    // keyboardSetUnicodeString expects UTF-16 code units, so Array(text.utf16)
    // gives the correct representation for all Unicode characters.
    let units  = Array(text.utf16)
    var idx    = 0
    while idx < units.count {
        let batchEnd = min(idx + 20, units.count)
        let batch    = Array(units[idx..<batchEnd])
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

/// Modifier keys, in the order a person presses them.
private let modifierKeys: [(CGEventFlags, CGKeyCode)] = [
    (.maskControl, 59), (.maskAlternate, 58), (.maskShift, 56), (.maskCommand, 55),
]

/// Presses a key with modifiers the way hardware does: modifier down (a
/// flagsChanged event), key down/up carrying the flags, modifier up. Sending
/// only the key events with flags set leaves the app believing the modifier is
/// still held, and the next typed text is swallowed as a shortcut — verified
/// against TextEdit: ⌘N then "alpha" typed nothing, with modifier events "beta".
private func postKeyPress(keyCode: CGKeyCode, flags: CGEventFlags) {
    let src  = CGEventSource(stateID: .hidSystemState)
    let held = modifierKeys.filter { flags.contains($0.0) }
    var accumulated: CGEventFlags = []
    for (flag, code) in held {
        accumulated.insert(flag)
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        e?.type = .flagsChanged
        e?.flags = accumulated
        e?.post(tap: .cghidEventTap)
    }
    let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
    let up   = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
    down?.flags = flags
    up?.flags   = flags
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
    for (flag, code) in held.reversed() {
        accumulated.remove(flag)
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        e?.type = .flagsChanged
        e?.flags = accumulated
        e?.post(tap: .cghidEventTap)
    }
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

    // Observer teardown context: set once after successful AXObserverCreate so
    // every resolve path can explicitly remove notifications before the observer
    // deallocs.  Protected by the same lock; written once, read once.
    private var _observerTeardown: (() -> Void)?

    func setUnmanaged(_ u: Unmanaged<WaitState>) {
        lock.lock(); defer { lock.unlock() }
        _unmanagedSelf = u
    }

    /// Store a teardown closure that explicitly removes AX observer notifications.
    /// Called once, immediately after the observer is set up.
    func setObserverTeardown(_ teardown: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        _observerTeardown = teardown
    }

    /// Release the retained self-reference exactly once, and run any observer teardown.
    func releaseRetained() {
        lock.lock()
        let u = _unmanagedSelf
        _unmanagedSelf = nil
        let teardown = _observerTeardown
        _observerTeardown = nil
        lock.unlock()
        teardown?()
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
// MARK: - CancellationBox (shared state for withTaskCancellationHandler in waitFor)
// ---------------------------------------------------------------------------
// Bridges the WaitState created inside withCheckedThrowingContinuation to the
// onCancel handler that lives outside the continuation body.  Written once
// (synchronously, before any await) and read once (in onCancel if cancellation
// races setup).  Access is safe: the write happens-before any concurrent read
// because the onCancel handler is only invoked after the Task is cancelled,
// which cannot happen before the continuation body returns from its synchronous
// setup phase.  We use NSLock for correctness in the (rare) race where
// cancellation is signalled while the continuation body is still running.

private final class CancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _state: WaitState?

    var state: WaitState? {
        get { lock.lock(); defer { lock.unlock() }; return _state }
        set { lock.lock(); defer { lock.unlock() }; _state = newValue }
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

    // Per-call timeout hint (seconds). Applied via AXUIElementSetMessagingTimeout on
    // the app element so AX calls to a hung app return an error instead of blocking.
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

    /// Everything a UINode needs, fetched together.
    static let nodeAttributes: [String] = [
        kAXRoleAttribute as String, kAXTitleAttribute as String, kAXDescriptionAttribute as String,
        kAXIdentifierAttribute as String, kAXValueAttribute as String, kAXPositionAttribute as String,
        kAXSizeAttribute as String, kAXEnabledAttribute as String,
    ]

    /// One IPC round trip for many attributes. Unsupported ones come back as an
    /// AXValue wrapping an AXError; those are dropped so callers see only real
    /// values. Falls back to per-attribute reads if the bulk call is refused.
    private func copyAttributes(_ el: AXUIElement, _ names: [String]) -> [String: Any] {
        var out: [String: Any] = [:]
        var values: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(el, names as CFArray, AXCopyMultipleAttributeOptions(), &values)
        if err == .success, let values = values as? [CFTypeRef], values.count == names.count {
            for (name, raw) in zip(names, values) {
                if CFGetTypeID(raw) == AXValueGetTypeID(),
                   AXValueGetType(raw as! AXValue) == .axError { continue }   // attribute unsupported here
                out[name] = raw
            }
            return out
        }
        for name in names {
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v { out[name] = v }
        }
        return out
    }

    /// CGRect from position/size AXValues already fetched in the bulk call.
    private func frameFrom(position: Any?, size: Any?) -> CGRect {
        var origin = CGPoint.zero, extent = CGSize.zero
        if let position, CFGetTypeID(position as CFTypeRef) == AXValueGetTypeID() {
            AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        }
        if let size, CFGetTypeID(size as CFTypeRef) == AXValueGetTypeID() {
            AXValueGetValue(size as! AXValue, .cgSize, &extent)
        }
        return CGRect(origin: origin, size: extent)
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
        // Apply per-call messaging timeout so a hung app returns an AX error
        // instead of blocking the actor indefinitely.
        AXUIElementSetMessagingTimeout(appElement, Float(callTimeout))

        // Hash of the app root element; used to detect self-referential AX trees.
        // On macOS 26+, kAXChildrenAttribute and kAXWindowsAttribute on an
        // AXUIElementCreateApplication element return the application element
        // itself as a child, creating infinite cycles.  We detect this by
        // comparing CFHash values and skip any element whose hash equals the
        // app root's hash (i.e. it IS the app root).
        let appRootHash = CFHash(appElement)

        // Recursive tree walk — all AX calls happen synchronously here, inside
        // the actor, so no concurrency issues with the AXUIElement handles.
        func walk(_ el: AXUIElement, depth: Int, isAppRoot: Bool = false) -> UINode {
            counter += 1
            let refStr = "e\(counter)"
            refCache[refStr] = AXElementBox(el)

            // ONE round trip for the eight attributes every node needs. Read
            // one at a time this cost ~11 IPC calls per node; a 2000-node
            // window (a file browser, an Open panel) took over ten seconds.
            let attrs = copyAttributes(el, Self.nodeAttributes)
            let role = (attrs[kAXRoleAttribute as String] as? String) ?? "unknown"

            // title (fallback to kAXDescriptionAttribute)
            var title = attrs[kAXTitleAttribute as String] as? String
            if title == nil || title!.isEmpty {
                title = attrs[kAXDescriptionAttribute as String] as? String
            }
            // A control labelled by a separate static text (AppKit's title
            // element, e.g. "File Format:" next to a pop-up) takes that label as
            // its title, so "File Format" resolves to the control, not the label.
            if title == nil || title!.isEmpty {
                var labelEl: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, kAXTitleUIElementAttribute as CFString, &labelEl) == .success, let labelEl {
                    var lv: CFTypeRef?
                    AXUIElementCopyAttributeValue(labelEl as! AXUIElement, kAXValueAttribute as CFString, &lv)
                    if let s = lv as? String, !s.isEmpty {
                        title = s.hasSuffix(":") ? String(s.dropLast()) : s
                    }
                }
            }
            if let t = title, t.isEmpty { title = nil }

            let identifier = attrs[kAXIdentifierAttribute as String] as? String
            let value: String? = stringifyAXValue(attrs[kAXValueAttribute as String] as CFTypeRef?)
            // frame (position + size — kAXFrameAttribute does not exist)
            let frame = frameFrom(position: attrs[kAXPositionAttribute as String],
                                  size: attrs[kAXSizeAttribute as String])
            let isEnabled = (attrs[kAXEnabledAttribute as String] as? Bool) ?? true

            // actions
            var actionsVal: CFArray?
            AXUIElementCopyActionNames(el, &actionsVal)
            let actions = (actionsVal as? [String]) ?? []

            // children (depth-cap 60 / node-cap 2000)
            var childrenNodes: [UINode] = []
            if depth < 60 && nodeCount < 2000 {
                // At the application root, compose the child list so that window
                // content is visited BEFORE the menu bar, spending the 2000-node
                // budget on agent-visible UI first.
                //
                // We filter out any child whose CFHash equals the app root's hash.
                // On macOS 26+ the AX framework returns the AXApplication element
                // itself as a member of kAXChildrenAttribute / kAXWindowsAttribute,
                // creating an infinite cycle.  Skipping self-referential entries
                // breaks the cycle without discarding real window or menu children.
                //
                // Order at the app root: non-MenuBar children first, AXMenuBar last.
                // Deeper levels use kAXChildrenAttribute as normal (no reordering).
                var childrenVal: CFTypeRef?
                let childErr = AXUIElementCopyAttributeValue(
                    el, kAXChildrenAttribute as CFString, &childrenVal)
                let rawChildren = (childErr == .success ? childrenVal as? [AXUIElement] : nil) ?? []

                let children: [AXUIElement]
                if isAppRoot {
                    // Remove self-referential entries (cycle guard).
                    let deduped = rawChildren.filter { CFHash($0) != appRootHash }
                    // Stable-partition: non-menubar first, AXMenuBar last.
                    var roleRef2: CFTypeRef?
                    let nonMenuBar = deduped.filter { c -> Bool in
                        AXUIElementCopyAttributeValue(c, kAXRoleAttribute as CFString, &roleRef2)
                        return (roleRef2 as? String) != "AXMenuBar"
                    }
                    let menuBar = deduped.filter { c -> Bool in
                        AXUIElementCopyAttributeValue(c, kAXRoleAttribute as CFString, &roleRef2)
                        return (roleRef2 as? String) == "AXMenuBar"
                    }
                    children = nonMenuBar + menuBar
                } else {
                    children = rawChildren
                }

                for child in children {
                    if nodeCount >= 2000 { capHit = true; break }
                    nodeCount += 1
                    childrenNodes.append(walk(child, depth: depth + 1))
                }
            } else if nodeCount >= 2000 {
                capHit = true
            }

            return UINode(ref: refStr, role: role, title: title, identifier: identifier,
                          value: value, frame: frame, isEnabled: isEnabled,
                          actions: actions, children: childrenNodes)
        }

        nodeCount = 1
        var root = walk(appElement, depth: 0, isAppRoot: true)

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

    public func click(bundleId: String, target: MacTarget, options: MacClickOptions = MacClickOptions()) async throws -> String {
        try checkTrust()
        let pid = try resolvePid(bundleId: bundleId)

        let (el, node) = try await resolveElement(target: target, bundleId: bundleId)

        // Double- and right-clicks are mouse gestures by definition.
        if options.clicks > 1 || options.rightButton {
            try await bringToFront(pid: pid)
            let point = try visiblePoint(of: el, fallback: node.frame)
            postMouseClick(at: point, clicks: max(1, min(options.clicks, 3)), right: options.rightButton)
            return options.rightButton ? "Right-clicked." : "Double-clicked."
        }

        if node.actions.contains(kAXPressAction as String) {
            let windowBefore = focusedWindow(pid: pid)
            let result = AXUIElementPerformAction(el, kAXPressAction as CFString)
            if result == .success { return "Pressed." }
            // Office apps return an error for presses that did take effect, and
            // a retry then repeats the action (three blank Word documents). If
            // the UI moved on — the focused window changed or the element is
            // gone — the press worked. Otherwise click with the mouse instead.
            try await Task.sleep(nanoseconds: 300_000_000)
            if !isValid(el) { return "Pressed (the element went away, so it took effect)." }
            if let before = windowBefore, let after = focusedWindow(pid: pid), !CFEqual(before, after) {
                return "Pressed (the front window changed, so it took effect)."
            }
            if windowBefore == nil, focusedWindow(pid: pid) != nil { return "Pressed (a window appeared)." }
            try await bringToFront(pid: pid)
            let point = try visiblePoint(of: el, fallback: node.frame)
            postMouseClick(at: point)
            return "Clicked with the mouse (the app rejected the accessibility press)."
        }
        // Rows and other selectable items: select through accessibility. A
        // synthetic mouse click on a System Settings search result does nothing,
        // while setting AXSelected navigates (verified against the live app).
        if Self.selectViaAccessibility(el) { return "Selected." }
        try await bringToFront(pid: pid)
        let point = try visiblePoint(of: el, fallback: node.frame)
        postMouseClick(at: point)
        return "Clicked with the mouse."
    }

    /// The element's on-screen centre, scrolling it into view first when the
    /// app supports that. Throws instead of clicking a point that is off every
    /// display, which would hit whatever happens to be there.
    private func visiblePoint(of el: AXUIElement, fallback: CGRect) throws -> CGPoint {
        var frame = fallback
        if !Self.isOnScreen(CGPoint(x: frame.midX, y: frame.midY)) {
            var names: CFArray?
            AXUIElementCopyActionNames(el, &names)
            if ((names as? [String]) ?? []).contains("AXScrollToVisible") {
                AXUIElementPerformAction(el, "AXScrollToVisible" as CFString)
                usleep(150_000)
                frame = axElementFrame(el)
            }
        }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        guard frame.width > 0, frame.height > 0, Self.isOnScreen(point) else {
            throw MacDriverError(code: "off_screen",
                                 message: "The element is not on screen (frame \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))). "
                                 + "Scroll it into view with mac_scroll, or target it by title so the app can reveal it.")
        }
        return point
    }

    /// AX coordinates are top-left based; NSScreen frames are bottom-left based.
    static func isOnScreen(_ p: CGPoint) -> Bool {
        guard let main = NSScreen.screens.first else { return true }
        let flippedY = main.frame.maxY - p.y
        return NSScreen.screens.contains { $0.frame.contains(CGPoint(x: p.x, y: flippedY)) }
    }

    // -------------------------------------------------------------------------
    // MARK: choose (pop-up buttons, menu buttons)
    // -------------------------------------------------------------------------

    public func choose(bundleId: String, target: MacTarget, item: String) async throws -> String {
        try checkTrust()
        let pid = try resolvePid(bundleId: bundleId)
        try await bringToFront(pid: pid)
        let (el, node) = try await resolveElement(target: target, bundleId: bundleId)
        // Open it: AXPress for pop-ups, else a mouse click (menu buttons in toolbars).
        if node.actions.contains(kAXPressAction as String) {
            AXUIElementPerformAction(el, kAXPressAction as CFString)
        } else {
            let p = try visiblePoint(of: el, fallback: node.frame)
            postMouseClick(at: p)
        }
        try await Task.sleep(nanoseconds: 350_000_000)
        // The open menu is a child of the element (pop-ups) or of the app (menu buttons).
        var seen: [(String, AXUIElement)] = []
        func collect(_ e: AXUIElement, _ depth: Int) {
            guard depth < 8 else { return }
            var r: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &r)
            if (r as? String) == "AXMenuBar" { return }          // the app's menus are not the open pop-up
            if (r as? String) == "AXMenuItem" {
                var t: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXTitleAttribute as CFString, &t)
                if let title = t as? String, !title.isEmpty { seen.append((title, e)) }
            }
            var c: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &c)
            for child in (c as? [AXUIElement]) ?? [] { collect(child, depth + 1) }
        }
        collect(el, 0)
        if seen.isEmpty { collect(AXUIElementCreateApplication(pid), 0) }
        let match = seen.first { $0.0 == item }
            ?? seen.first { $0.0.caseInsensitiveCompare(item) == .orderedSame }
            ?? seen.first { $0.0.range(of: item, options: .caseInsensitive) != nil }
        guard let match else {
            postKeyPress(keyCode: 53, flags: [])   // Escape: leave no menu hanging open
            let list = seen.map(\.0).prefix(30).joined(separator: " | ")
            throw MacDriverError(code: "no_such_item",
                                 message: "No item '\(item)' in that menu. Items: \(list.isEmpty ? "(none visible)" : list)")
        }
        let r = AXUIElementPerformAction(match.1, kAXPressAction as CFString)
        guard r == .success else {
            postKeyPress(keyCode: 53, flags: [])
            throw MacDriverError(code: "ax_error", message: "Could not choose '\(match.0)' (\(r.rawValue)).")
        }
        return "Chose '\(match.0)'."
    }

    // -------------------------------------------------------------------------
    // MARK: scroll
    // -------------------------------------------------------------------------

    public func scroll(bundleId: String, target: MacTarget?, direction: String, amount: Int) async throws {
        try checkTrust()
        let pid = try resolvePid(bundleId: bundleId)
        try await bringToFront(pid: pid)
        let frame: CGRect
        if let target {
            let (el, node) = try await resolveElement(target: target, bundleId: bundleId)
            frame = node.frame.width > 0 ? node.frame : axElementFrame(el)
        } else if let win = focusedWindow(pid: pid) {
            frame = axElementFrame(win)
        } else {
            throw MacDriverError(code: "no_window", message: "\(bundleId) has no front window to scroll.")
        }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        guard Self.isOnScreen(point) else {
            throw MacDriverError(code: "off_screen", message: "The scroll target is not on screen.")
        }
        let lines = Int32(max(1, min(amount, 100)))
        var dy: Int32 = 0, dx: Int32 = 0
        switch direction.lowercased() {
        case "up":    dy = lines
        case "down":  dy = -lines
        case "left":  dx = lines
        case "right": dx = -lines
        default: throw MacDriverError(code: "bad_direction", message: "direction must be up, down, left or right")
        }
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(30_000)
        // Several small wheel events scroll more reliably than one big one.
        let steps = Int(lines)
        for _ in 0..<steps {
            if let ev = CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 2,
                                wheel1: dy == 0 ? 0 : (dy > 0 ? 1 : -1), wheel2: dx == 0 ? 0 : (dx > 0 ? 1 : -1), wheel3: 0) {
                ev.post(tap: .cghidEventTap)
            }
            usleep(8_000)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    private func focusedWindow(pid: pid_t) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &v) == .success,
              let v else { return nil }
        return (v as! AXUIElement)
    }

    private func isValid(_ el: AXUIElement) -> Bool {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v) != .invalidUIElement
    }

    /// Sets AXSelected on an element that allows it and confirms the app took it.
    static func selectViaAccessibility(_ el: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(el, kAXSelectedAttribute as CFString, &settable) == .success,
              settable.boolValue,
              AXUIElementSetAttributeValue(el, kAXSelectedAttribute as CFString, true as CFBoolean) == .success
        else { return false }
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXSelectedAttribute as CFString, &v)
        return (v as? Bool) ?? true
    }

    // -------------------------------------------------------------------------
    // MARK: type
    // -------------------------------------------------------------------------

    /// Returns true when the focused field was read back and contains the text;
    /// false when it was sent but the field's content cannot be read at all.
    /// Throws when the field could be read and the text is not there.
    public func type(bundleId: String, text: String, target: MacTarget?, replace: Bool = false) async throws -> Bool {
        try checkTrust()
        let pid = try resolvePid(bundleId: bundleId)

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

        // Keystrokes go to the frontmost app, so make sure that is the target.
        try await bringToFront(pid: pid)

        // A shortcut like ⌘N creates its editor asynchronously; typing before an
        // editable element owns keyboard focus is swallowed with a beep.
        guard let focused = await waitForEditableFocus(pid: pid, timeoutSeconds: 2.0) else {
            let role = focusedRole(pid: pid) ?? "nothing"
            throw MacDriverError(code: "no_text_focus",
                                 message: "No editable element has keyboard focus in \(bundleId) "
                                 + "(focused: \(role)). Click into a text field first with mac_click, "
                                 + "or pass ref/title/identifier to mac_type.")
        }
        if replace {
            postKeyPress(keyCode: 0, flags: .maskCommand)   // ⌘A
            usleep(60_000)
        }
        let beforeText = replace ? "" : axStringValue(focused)
        let beforeCount = replace ? 0 : axCharCount(focused)
        postUnicodeText(text)

        // Verify the text landed: by content when the field exposes it, else by
        // its character count (NSTextView always reports that).
        var readable = beforeText != nil || beforeCount != nil
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if let after = axStringValue(focused) {
                readable = true
                if Self.contains(after, allLinesOf: text) { commitPendingTextInput(focused); return true }
            }
            if let count = axCharCount(focused) {
                readable = true
                if count >= (beforeCount ?? 0) + text.count { commitPendingTextInput(focused); return true }
            }
        }
        // Secure fields and some web views expose nothing to read back.
        guard readable else { commitPendingTextInput(focused); return false }
        throw MacDriverError(code: "type_unverified",
                             message: "The keystrokes were sent but the focused \(role(of: focused) ?? "element") "
                             + "did not receive the text. \(frontWindowSummary(pid: pid)) Click into the intended "
                             + "text field with mac_click (or pass its ref/title to mac_type) and try again.")
    }

    /// "Front window: 'Untitled' (a sheet 'Save' is open)." — the usual reason
    /// typing goes nowhere is a dialog the model has not noticed.
    private func frontWindowSummary(pid: pid_t) -> String {
        guard let win = focusedWindow(pid: pid) else { return "The app has no front window." }
        var t: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &t)
        let title = (t as? String) ?? ""
        var s: CFTypeRef?
        AXUIElementCopyAttributeValue(win, "AXSheets" as CFString, &s)
        if let sheets = s as? [AXUIElement], let sheet = sheets.first {
            var st: CFTypeRef?
            AXUIElementCopyAttributeValue(sheet, kAXTitleAttribute as CFString, &st)
            let sheetTitle = (st as? String).map { " '\($0)'" } ?? ""
            return "Front window: '\(title)' — a sheet\(sheetTitle) is open and must be answered first (read it with mac_ui)."
        }
        return "Front window: '\(title)'."
    }

    /// True when every non-blank line of `text` appears in `content`. Line by
    /// line, because the field may turn a typed newline into a paragraph break
    /// or styled heading and the exact string never matches.
    static func contains(_ content: String, allLinesOf text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return true }
        // Apps rewrite what was typed: auto-capitalisation, smart quotes and
        // dashes, non-breaking spaces. Compare with those folded away.
        let folded = fold(content)
        return lines.allSatisfy { folded.contains(fold($0)) }
    }

    static func fold(_ s: String) -> String {
        var out = s.lowercased()
        for (from, to) in [("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{201C}", "\""), ("\u{201D}", "\""),
                           ("\u{2013}", "-"), ("\u{2014}", "-"), ("\u{00A0}", " "), ("\u{2026}", "...")] {
            out = out.replacingOccurrences(of: from, with: to)
        }
        return out
    }

    /// Text views hold auto-capitalisation / autocorrect of the last word until
    /// the NEXT key event, and that commit collapses whatever selection the next
    /// command just made (⌘A right after typing selected nothing — verified in
    /// TextEdit). A caret move commits it harmlessly: Right at the end of the
    /// text is a no-op; elsewhere Right then Left leaves the caret where it was.
    private func commitPendingTextInput(_ el: AXUIElement) {
        var atEnd = true
        var rangeVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeVal) == .success,
           let rangeVal, CFGetTypeID(rangeVal) == AXValueGetTypeID() {
            var r = CFRange()
            if AXValueGetValue(rangeVal as! AXValue, .cfRange, &r), let count = axCharCount(el) {
                atEnd = r.location + r.length >= count
            }
        }
        postKeyPress(keyCode: 124, flags: [])            // →
        if !atEnd { usleep(20_000); postKeyPress(keyCode: 123, flags: []) }   // ← back to where we were
        usleep(60_000)
    }

    /// Roles whose focused element accepts typed text.
    static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea", "AXSecureTextField",
    ]

    /// Make the target app active. Keystrokes and mouse events go to whatever is
    /// in front, so this throws rather than let a call land in another app.
    private func bringToFront(pid: pid_t) async throws {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        // `isActive` lags in a process without a live AppKit run loop; the
        // workspace's frontmost app is authoritative. Re-activating an app that
        // is already in front reorders its windows, so never do it needlessly.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid || app.isActive { return }
        app.activate(options: [])
        for _ in 0..<20 where !app.isActive { try? await Task.sleep(nanoseconds: 50_000_000) }   // 1 s
        if app.isActive { return }
        // Cooperative activation can refuse a background caller; opening the app
        // through NSWorkspace with `activates` is honoured regardless.
        if let url = app.bundleURL {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            for _ in 0..<30 where !app.isActive { try? await Task.sleep(nanoseconds: 50_000_000) }   // 1.5 s
        }
        guard app.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "another app"
            throw MacDriverError(code: "not_frontmost",
                                 message: "Could not bring \(app.localizedName ?? "the app") to the front (\(front) stayed in front), "
                                 + "so no keys were sent. Retry, or ask the user to switch to it.")
        }
    }

    private func focusedElement(pid: pid_t) -> AXUIElement? {
        var ref: CFTypeRef?
        let appEl = AXUIElementCreateApplication(pid)
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref else { return nil }
        return (ref as! AXUIElement)
    }

    private func role(of el: AXUIElement) -> String? {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v)
        return v as? String
    }

    private func focusedRole(pid: pid_t) -> String? {
        focusedElement(pid: pid).flatMap { role(of: $0) }
    }

    private func axStringValue(_ el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success else { return nil }
        return stringifyAXValue(v)
    }

    private func axCharCount(_ el: AXUIElement) -> Int? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXNumberOfCharactersAttribute as CFString, &v) == .success else { return nil }
        return (v as? NSNumber)?.intValue
    }

    /// The focused element once it is editable: a known text role, or any
    /// element whose value can be set. Polls for up to `timeoutSeconds`.
    private func waitForEditableFocus(pid: pid_t, timeoutSeconds: Double) async -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        repeat {
            if let el = focusedElement(pid: pid) {
                if let r = role(of: el), Self.editableRoles.contains(r) { return el }
                var settable: DarwinBoolean = false
                if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success,
                   settable.boolValue { return el }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        } while Date() < deadline
        return nil
    }

    // -------------------------------------------------------------------------
    // MARK: key
    // -------------------------------------------------------------------------

    public func key(bundleId: String, keys: String) async throws {
        try checkTrust()
        let pid = try resolvePid(bundleId: bundleId)
        try await bringToFront(pid: pid)   // a shortcut must never land in another app

        try await Task.sleep(nanoseconds: 250_000_000)   // let a preceding edit settle (autocorrect, focus)
        let combos = keys.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !combos.isEmpty else { throw MacDriverError(code: "bad_key", message: "No key given.") }
        var parsed: [(CGKeyCode, CGEventFlags)] = []
        for combo in combos {
            guard let p = parseKeyCombo(combo) else {
                throw MacDriverError(code: "bad_key",
                                     message: "Cannot parse key combo: \(combo). Use names like return, backspace, escape, tab, up, or combos like cmd+s; separate a sequence with commas.")
            }
            parsed.append(p)
        }
        for (i, (keyCode, flags)) in parsed.enumerated() {
            postKeyPress(keyCode: keyCode, flags: flags)
            // A copy needs time to reach the pasteboard before the next combo pastes it.
            if i < parsed.count - 1 { try await Task.sleep(nanoseconds: 200_000_000) }
        }
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
        // A shared CancellationBox lets the onCancel handler (which fires outside
        // the actor) reach the WaitState that is created inside the continuation
        // body.  The box is written once (inside the continuation, before anything
        // awaits) and read once (in onCancel if cancellation races the setup).
        // The exactly-once guarantee is preserved because onCancel goes through the
        // same flag.tryResolve() → releaseRetained() → continuation.resume() path
        // used by the observer and timeout paths.
        let cancelBox = CancellationBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let state    = WaitState(continuation: continuation, bundleId: bundleId,
                                         target: target, forDisappearance: forDisappearance,
                                         client: self)
                // Publish state before registering the observer so onCancel always
                // sees a non-nil state if it fires after this point.
                cancelBox.state = state

                let statePtr = Unmanaged.passRetained(state)
                // Store the unmanaged pointer inside state so the C callback can
                // release it without capturing a raw UnsafeMutableRawPointer.
                state.setUnmanaged(statePtr)

                var observer: AXObserver?
                let createErr = AXObserverCreate(pid, axObserverCallback, &observer)
                guard createErr == .success, let obs = observer else {
                    if state.flag.tryResolve() {
                        state.releaseRetained()
                        continuation.resume(throwing: MacDriverError(
                            code: "ax_error",
                            message: "AXObserverCreate failed: \(createErr.rawValue)"))
                    }
                    return
                }

                let appElement    = AXUIElementCreateApplication(pid)
                // Apply per-call messaging timeout for the observer's app element too.
                AXUIElementSetMessagingTimeout(appElement, Float(callTimeout))
                let notifications = [kAXValueChangedNotification,
                                     kAXCreatedNotification,
                                     kAXFocusedUIElementChangedNotification]
                for note in notifications {
                    AXObserverAddNotification(obs, appElement, note as CFString,
                                             statePtr.toOpaque())
                }

                // Register an explicit teardown so every resolve path removes
                // the notifications before the observer is released.  The one-shot
                // flag guarantees this closure runs exactly once (inside
                // releaseRetained(), which is called by the winner of the resolve
                // race — observer callback, timeout, or cancellation).
                let appElementBox = AXElementBox(appElement)
                let observerBox2  = AXObserverBox(obs)
                state.setObserverTeardown {
                    for note in notifications {
                        AXObserverRemoveNotification(observerBox2.observer,
                                                     appElementBox.element,
                                                     note as CFString)
                    }
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
        } onCancel: {
            // onCancel is called synchronously on the cancelling thread when the
            // Task owning this continuation is cancelled.  We win the one-shot
            // race (tryResolve) and resume the continuation with CancellationError,
            // then call releaseRetained() — identical teardown to observer/timeout.
            // If another path already won, tryResolve() returns false and we no-op.
            if let state = cancelBox.state, state.flag.tryResolve() {
                state.releaseRetained()
                state.continuation.resume(throwing: CancellationError())
            }
        }
    }

    // -------------------------------------------------------------------------
    // MARK: launch / runningApps
    // -------------------------------------------------------------------------

    public func launch(bundleId: String) async throws {
        try await AppResolver.launch(bundleId: bundleId)
        // A freshly launched app has no window for a moment; a read taken then
        // is empty and the model concludes the app failed to open.
        guard let pid = AppResolver.pid(forBundleId: bundleId) else { return }
        let appEl = AXUIElementCreateApplication(pid)
        for _ in 0..<40 {                                   // up to ~4 s
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &v) == .success,
               let wins = v as? [AXUIElement], !wins.isEmpty { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    public nonisolated func runningApps() -> [(name: String, bundleId: String)] {
        AppResolver.runningApps()
    }

    // -------------------------------------------------------------------------
    // MARK: screenshot (opt-in; the tree is the primary way to see)
    // -------------------------------------------------------------------------

    /// PNG of the app's front window, longest side capped at 1600 px so a
    /// screenshot costs a bounded number of vision tokens.
    public func screenshot(bundleId: String) async throws -> Data {
        let pid = try resolvePid(bundleId: bundleId)
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw MacDriverError(code: "screen_recording",
                                 message: "Cannot capture the screen: Screen Recording permission is not granted "
                                 + "(System Settings → Privacy & Security → Screen & System Audio Recording). "
                                 + "Read the window with mac_ui instead. (\(error.localizedDescription))")
        }
        guard let win = content.windows.first(where: {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 50 && $0.frame.height > 50
        }) else {
            throw MacDriverError(code: "no_window", message: "\(bundleId) has no visible window to capture.")
        }
        let cfg = SCStreamConfiguration()
        let longest = max(win.frame.width, win.frame.height)
        let factor = min(2.0, 1600.0 / longest)            // retina up to the cap
        cfg.width = Int(win.frame.width * factor)
        cfg.height = Int(win.frame.height * factor)
        cfg.showsCursor = false
        guard #available(macOS 14.0, *) else {
            throw MacDriverError(code: "unsupported", message: "Screenshots need macOS 14 or newer; read the window with mac_ui instead.")
        }
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: win),
                                                               configuration: cfg)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw MacDriverError(code: "encode_failed", message: "Could not encode the screenshot.")
        }
        return png
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
    /// 1. If ref is present, generation MUST also be present and equal the current
    ///    generation — otherwise the ref is stale/ambiguous and we throw immediately.
    ///    We do NOT allow a ref to fall through to title/identifier matching because
    ///    the ref numbering (e1, e2, …) is reset on every snapshot call; a ref from
    ///    a prior snapshot can match an entirely different element in a fresh snapshot.
    /// 2. If ref is nil, take a fresh snapshot and search depth-first by title/identifier.
    private func resolveElement(
        target: MacTarget,
        bundleId: String
    ) async throws -> (AXUIElement, UINode) {
        // Ref path: generation is REQUIRED to guard against stale-ref collisions.
        if let ref = target.ref {
            guard let targetGen = target.generation else {
                throw MacDriverError(code: "stale_ref",
                                     message: "ref requires a matching generation — call mac_ui again and use fresh refs")
            }
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

        // No ref: fresh snapshot + depth-first search by title/identifier.
        let snap = try await snapshot(bundleId: bundleId)
        if let (el, node) = findInSnapshot(snap.root, target: target) {
            return (el, node)
        }
        throw MacDriverError(code: "not_found",
                             message: "No element matching \(target)",
                             tree: snap)
    }

    /// Depth-first search returning (AXUIElement, UINode) when target matches.
    /// Staged search: exact title/value/identifier first, then case-insensitive,
    /// then a substring of the visible text. Models paraphrase ("sound" for
    /// "Sound", "Save" for "Save…"); exact-only matching sent them in circles.
    private func findInSnapshot(
        _ node: UINode,
        target: MacTarget
    ) -> (AXUIElement, UINode)? {
        // Controls first at every stage: "File Format" must resolve to the
        // pop-up button, not the static label that precedes it in the tree.
        for stage in 0..<3 {
            if let found = find(node, target: target, stage: stage, controlsOnly: true) { return found }
        }
        for stage in 0..<3 {
            if let found = find(node, target: target, stage: stage, controlsOnly: false) { return found }
        }
        return nil
    }

    private static func isControl(_ node: UINode) -> Bool {
        UITree.interactiveRoles.contains(node.role) || node.role == "AXRow" || node.role == "AXCell"
            || node.role == "AXMenuItem" || node.role == "AXMenuBarItem" || node.role == "AXTab"
            || node.actions.contains(kAXPressAction as String)
    }

    private func find(_ node: UINode, target: MacTarget, stage: Int, controlsOnly: Bool) -> (AXUIElement, UINode)? {
        func textMatch(_ candidate: String?, _ wanted: String) -> Bool {
            guard let c = candidate else { return false }
            switch stage {
            case 0:  return c == wanted
            case 1:  return c.caseInsensitiveCompare(wanted) == .orderedSame
            default: return c.range(of: wanted, options: .caseInsensitive) != nil
            }
        }
        // `title` also matches a node's visible value: table cells expose their
        // text as value, and rows beyond the render cap are only known by text.
        let titleMatch = target.title.map      { textMatch(node.title, $0) || textMatch(node.value, $0) } ?? true
        let idMatch    = target.identifier.map { textMatch(node.identifier, $0) } ?? true
        let refMatch   = target.ref.map        { node.ref == $0 } ?? true
        if titleMatch && idMatch && refMatch, !controlsOnly || Self.isControl(node), let box = refCache[node.ref] {
            return (box.element, node)
        }
        for child in node.children {
            if let found = find(child, target: target, stage: stage, controlsOnly: controlsOnly) { return found }
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
