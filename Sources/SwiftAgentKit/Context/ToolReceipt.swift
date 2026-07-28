//
//  ToolReceipt.swift
//  SwiftAgentKit
//
//  A compact stand-in for a completed tool exchange. The receipt tells the model
//  what ran and how to retrieve the full output; the raw result no longer sits
//  in active context.
//

import Foundation

public struct ToolReceipt: Sendable, Equatable {
    public let callID: String
    public let toolName: String
    public let isError: Bool
    public let summary: String
    public let artifactIDs: [String]
    /// A short representation of the call's key argument (e.g. the shell command
    /// or file path), so the ledger says WHICH invocation this was — not just
    /// that some `run_shell` ran. `nil` when there's no salient argument.
    public let argHint: String?

    public init(callID: String, toolName: String, isError: Bool, summary: String, artifactIDs: [String], argHint: String? = nil) {
        self.callID = callID
        self.toolName = toolName
        self.isError = isError
        self.summary = summary
        self.artifactIDs = artifactIDs
        self.argHint = argHint
    }

    /// One ledger line, e.g.
    /// `call_1 run_shell(python3 build.py) → ERROR: … UnicodeEncodeError … [artifact-abc123]`
    public func ledgerLine() -> String {
        let status = isError ? "ERROR" : "OK"
        let arg = argHint.map { "(\($0))" } ?? ""
        let artifacts = artifactIDs.isEmpty ? "" : " [\(artifactIDs.joined(separator: ", "))]"
        return "\(callID) \(toolName)\(arg) → \(status): \(summary)\(artifacts)"
    }
}
