//
//  ToolRetry.swift
//  SwiftAgentKit
//
//  Which tool failures are worth one more try. Decided by the error's TYPE
//  (or by the tool, on its result) — never by reading the message text.
//  The dispatcher retries a call once, and only for tools whose
//  `retriesTransientFailures` is true (read-only tools, by default).
//

import Foundation

/// An error a tool throws that knows whether trying again in a moment can work.
public protocol TransientToolError: Error {
    var isTransient: Bool { get }
}

public enum ToolRetry {
    /// URL-loading failures a second attempt a moment later usually fixes.
    /// `cannotConnectToHost` is not one: nothing is listening.
    static let transientURLCodes: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .dnsLookupFailed]

    /// POSIX errors of the same kind (a reset or timed-out connection, a busy resource).
    static let transientPOSIXCodes: Set<Int32> = [ECONNRESET, ETIMEDOUT, EAGAIN]

    public static func isTransient(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let tagged = error as? TransientToolError { return tagged.isTransient }
        if let url = error as? URLError { return transientURLCodes.contains(url.code) }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return transientURLCodes.contains(URLError.Code(rawValue: ns.code)) }
        if ns.domain == NSPOSIXErrorDomain { return transientPOSIXCodes.contains(Int32(truncatingIfNeeded: ns.code)) }
        return false
    }

    /// A first attempt's outcome: an error result the tool marked transient,
    /// or a thrown error of a transient type.
    public static func isTransient(_ outcome: Result<AgentToolResult, Error>) -> Bool {
        switch outcome {
        case .success(let result): return result.isError && result.isTransient
        case .failure(let error): return isTransient(error)
        }
    }

    /// The first attempt's error text, for the `.toolCallRetried` event.
    public static func describe(_ outcome: Result<AgentToolResult, Error>) -> String {
        switch outcome {
        case .success(let result): return result.result
        case .failure(let error): return error.localizedDescription
        }
    }
}
