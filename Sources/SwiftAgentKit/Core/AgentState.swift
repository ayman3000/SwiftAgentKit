//
//  AgentState.swift
//  SwiftAgentKit
//
//  Cross-turn mutable state — inspired by Google ADK's `session.state`.
//
//  Tools can read/write state. Instructions can template from state.
//  State persists across turns within a session.
//

import Foundation

/// A thread-safe, mutable key-value store that persists across agent turns.
///
/// This is the agent's "scratchpad" — tools can write data here and other
/// tools (or the next turn's LLM call) can read it back.
///
/// State scoping is by key prefix (same as ADK):
/// - `app:key` → app-wide (persists across sessions)
/// - `user:key` → user-wide (persists across sessions for the same user)
/// - `temp:key` → single invocation only (cleared after each run)
/// - `key` (no prefix) → session-scoped (persists across turns within a session)
///
public final class AgentState: @unchecked Sendable {

    private var storage: [String: Any] = [:]
    private let lock = NSLock()

    public init() {}

    // MARK: - Read

    public func value(forKey key: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    public func string(forKey key: String) -> String? {
        value(forKey: key) as? String
    }

    public func int(forKey key: String) -> Int? {
        value(forKey: key) as? Int
    }

    public func double(forKey key: String) -> Double? {
        value(forKey: key) as? Double
    }

    public func bool(forKey key: String) -> Bool? {
        value(forKey: key) as? Bool
    }

    public func array(forKey key: String) -> [Any]? {
        value(forKey: key) as? [Any]
    }

    public func dict(forKey key: String) -> [String: Any]? {
        value(forKey: key) as? [String: Any]
    }

    // MARK: - Write

    public func setValue(_ value: Any, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = value
    }

    public func removeValue(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }

    // MARK: - Snapshot

    /// Get a snapshot of all state values.
    public func snapshot() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// Get a snapshot of non-temp state (for instruction templating).
    public func nonTempSnapshot() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return storage.filter { !$0.key.hasPrefix("temp:") }
    }

    // MARK: - Clear

    /// Clear all temp: prefixed values (call after each run).
    public func clearTemp() {
        lock.lock()
        defer { lock.unlock() }
        storage = storage.filter { !$0.key.hasPrefix("temp:") }
    }

    /// Clear everything.
    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }

    // MARK: - Instruction Templating

    /// Replace `{key}` placeholders in a string with state values.
    public func template(_ text: String) -> String {
        let snap = snapshot()
        var result = text
        for (key, value) in snap {
            let placeholder = "{\(key)}"
            result = result.replacingOccurrences(of: placeholder, with: "\(value)")
        }
        return result
    }

    // MARK: - Subscript convenience

    public subscript(key: String) -> Any? {
        get { value(forKey: key) }
        set {
            if let newValue {
                setValue(newValue, forKey: key)
            } else {
                removeValue(forKey: key)
            }
        }
    }
}