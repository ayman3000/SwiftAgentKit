//
//  AppleScriptRunner.swift
//  SwiftAgentKitMac
//
//  Mail and Notes have no public framework; they answer Apple Events. This is
//  the one place a script is executed, on its own serial queue so a slow
//  mailbox never stalls the host's main thread. Everything above it builds
//  script text and parses the delimited records that come back.
//
//  The host needs `NSAppleEventsUsageDescription` and, under Hardened
//  Runtime, the `com.apple.security.automation.apple-events` entitlement;
//  macOS then asks the user once per target app. A refusal is error -1743,
//  which is turned into a sentence that says where to allow it.
//

#if os(macOS)
import Foundation

/// Runs AppleScript source and returns its string result. Mockable.
public protocol AppleScripting: Sendable {
    func run(_ source: String) async throws -> String
}

public struct AppleScriptError: LocalizedError, Equatable {
    public let code: Int
    public let message: String
    public var errorDescription: String? {
        switch code {
        case -1743:
            return "macOS has not allowed Naseem to control that app. Allow it in System Settings ▸ Privacy & Security ▸ Automation, then try again."
        case -600, -609:
            return "That app is not running and could not be reached. Open it once, then try again."
        default:
            return message
        }
    }
}

/// The real runner: NSAppleScript on a private serial queue.
public final class NSAppleScriptRunner: AppleScripting, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SwiftAgentKitMac.AppleScript", qos: .userInitiated)
    public init() {}

    public func run(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                var errorInfo: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(throwing: AppleScriptError(code: -1, message: "The script could not be compiled."))
                    return
                }
                let result = script.executeAndReturnError(&errorInfo)
                if let errorInfo {
                    let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? -1
                    let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "AppleScript failed."
                    continuation.resume(throwing: AppleScriptError(code: code, message: message))
                    return
                }
                continuation.resume(returning: result.stringValue ?? "")
            }
        }
    }
}

/// Text the tools and scripts agree on: how records are delimited, how a
/// Swift string becomes a safe AppleScript literal, how dates cross.
public enum AppleScriptText {
    /// Field separator inside a record, record separator between records —
    /// two control characters no subject line or note contains.
    public static let field: Character = "\u{1F}"
    public static let record: Character = "\u{1E}"

    /// `set fs to character id 31` etc., to paste at the top of a script.
    public static let delimiterPrelude = """
    set fs to character id 31
    set rs to character id 30
    """

    /// Make sure an app is up before talking to it: the first event to an
    /// app that is still launching fails with -609 "connection is invalid".
    public static func launchGuard(_ app: String) -> String {
        """
        tell application \(literal(app))
            if not running then launch
            set tries to 0
            repeat until running or tries > 20
                delay 0.25
                set tries to tries + 1
            end repeat
        end tell
        """
    }

    /// A Swift string as an AppleScript string literal, escaped.
    public static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Records back into fields, dropping empty trailing records.
    public static func records(_ text: String) -> [[String]] {
        text.split(separator: record, omittingEmptySubsequences: true)
            .map { $0.split(separator: field, omittingEmptySubsequences: false).map(String.init) }
    }

    /// `(d as «class isot») as string` gives "2026-09-19T10:00:00" in the
    /// Mac's own time zone; this reads it back the same way.
    public static func date(fromISO s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: String(s.prefix(19)))
    }
}

/// ISO 8601 with the Mac's time zone, for every date that reaches the model
/// and every date the model sends back.
public enum AppleDates {
    // Formatters are not Sendable; make fresh ones per call — these are
    // called a few dozen times per tool call, never in a hot loop.
    private static func formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }
    private static func dayFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    public static func string(_ d: Date) -> String { formatter().string(from: d) }

    /// Accepts "2026-09-19T15:00:00+03:00", "2026-09-19T15:00", or a bare
    /// day "2026-09-19" (midnight, local).
    public static func parse(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let d = formatter().date(from: t) { return d }
        if t.count >= 16, let d = AppleScriptText.date(fromISO: t + (t.count == 16 ? ":00" : "")) { return d }
        return dayFormatter().date(from: t)
    }

    /// A readable line for the model: "Fri 19 Sep, 15:00–16:00".
    public static func span(_ start: Date, _ end: Date, allDay: Bool) -> String {
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.timeZone = .current; day.dateFormat = "EEE d MMM"
        let time = DateFormatter(); time.locale = Locale(identifier: "en_US_POSIX"); time.timeZone = .current; time.dateFormat = "HH:mm"
        if allDay { return day.string(from: start) + " (all day)" }
        if Calendar.current.isDate(start, inSameDayAs: end) {
            return "\(day.string(from: start)), \(time.string(from: start))–\(time.string(from: end))"
        }
        return "\(day.string(from: start)) \(time.string(from: start)) → \(day.string(from: end)) \(time.string(from: end))"
    }
}
#endif
