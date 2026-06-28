//
//  AgentLogger.swift
//  SwiftAgentKit
//
//  A simple logging facility for agent events.
//  Inspired by lightweight UI logging callback patterns.
//

import Foundation

/// Log level for agent messages.
///
public enum AgentLogLevel: Int, Sendable, Comparable {

    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    public static func < (lhs: AgentLogLevel, rhs: AgentLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A simple logger for agent activity.
///
/// Usage:
/// ```swift
/// let logger = AgentLogger(minLevel: .info)
/// logger.info("Agent started")
/// logger.error("Tool failed: \(error)")
/// ```
///
/// By default, logs to `os_log` / `print`. Set a custom handler to route logs elsewhere.
///
public final class AgentLogger: @unchecked Sendable {

    public var minLevel: AgentLogLevel
    public var handler: ((AgentLogLevel, String) -> Void)?

    public init(minLevel: AgentLogLevel = .info, handler: ((AgentLogLevel, String) -> Void)? = nil) {
        self.minLevel = minLevel
        self.handler = handler
    }

    public func debug(_ message: @autoclosure () -> String) {
        log(.debug, message())
    }

    public func info(_ message: @autoclosure () -> String) {
        log(.info, message())
    }

    public func warning(_ message: @autoclosure () -> String) {
        log(.warning, message())
    }

    public func error(_ message: @autoclosure () -> String) {
        log(.error, message())
    }

    private func log(_ level: AgentLogLevel, _ message: String) {
        guard level >= minLevel else { return }

        if let handler {
            handler(level, message)
        } else {
            print("[\(level.emoji)] \(message)")
        }
    }
}

extension AgentLogLevel {
    var emoji: String {
        switch self {
        case .debug: return "🔍"
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        }
    }

    var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }
}