//
//  RepairRetryPolicy.swift
//  SwiftAgentKit
//
//  Repair retry policy — pure, testable decision logic
//  for when to nudge the model to fix a failed tool call instead of accepting
//  its narration of "success".
//

import Foundation

/// Policy for when to repair-retry after a tool error.
///
/// When a tool fails but the model tries to narrate success and
/// end the turn, the loop forces a "fix and retry" nudge instead of accepting
/// the false success. This prevents the "model claims success after a failed
/// command" failure mode.
///
public struct RepairRetryPolicy: @unchecked Sendable {

    /// Maximum repair-retry attempts.
    public var maxAttempts: Int

    /// Whether a tool result is repairable (transient error, not a permanent failure).
    public var isRepairable: @Sendable (AgentToolResult) -> Bool

    public init(
        maxAttempts: Int = 3,
        isRepairable: @Sendable @escaping (AgentToolResult) -> Bool = { result in
            // Default: retry on any error except "tool not found" or "duplicate"
            let message = result.result.lowercased()
            return result.isError &&
                !message.contains("not registered") &&
                !message.contains("not found") &&
                !message.contains("duplicate")
        }
    ) {
        self.maxAttempts = maxAttempts
        self.isRepairable = isRepairable
    }

    /// Whether we should retry based on the errors from the last turn.
    public func shouldRetry(
        repairableErrors: [AgentToolResult],
        attemptsUsed: Int,
        turnsRemaining: Int
    ) -> Bool {
        !repairableErrors.isEmpty &&
        attemptsUsed < maxAttempts &&
        turnsRemaining > 0
    }

    /// Build a nudge message for the model to fix its errors.
    public func nudge(for errors: [AgentToolResult]) -> String {
        let errorList = errors.map { error in
            "• Tool \(error.toolName ?? "unknown"): \(error.result)"
        }.joined(separator: "\n")

        return """
        The previous tool call(s) failed with errors:

        \(errorList)

        You must fix these errors and retry. Do NOT claim success or say "Done" \
        until all operations actually succeed. Analyze the error, adjust your \
        approach if needed, and try again.
        """
    }
}

/// Policy for when to nudge the model to continue the plan.
///
/// If the plan isn't complete but the model stops calling tools,
/// the loop nudges it (up to N times) with the pending step list.
///
public struct PlanContinuationPolicy: Sendable {

    /// Maximum continuation nudges.
    public var maxAttempts: Int

    public init(maxAttempts: Int = 10) {
        self.maxAttempts = maxAttempts
    }

    /// Whether we should nudge the model to continue the plan.
    public func shouldContinue(
        plan: AgentPlan,
        attemptsUsed: Int,
        turnsRemaining: Int
    ) -> Bool {
        plan.hasPendingSteps &&
        attemptsUsed < maxAttempts &&
        turnsRemaining > 0
    }

    /// Build a continuation nudge message.
    public func nudge(for plan: AgentPlan) -> String {
        let pending = plan.pendingSteps.prefix(5).map { "• \($0.step)" }
            .joined(separator: "\n")

        return """
        You must continue executing the remaining plan steps. Do NOT stop until \
        all steps are complete. Here are the pending steps:

        \(pending)

        Continue with the next step.
        """
    }
}