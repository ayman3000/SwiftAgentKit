//
//  GoalVerdict.swift
//  SwiftAgentKit
//
//  The result of verifying whether a run actually achieved its goal, before the
//  agent is allowed to stop. Enables goal-driven looping: keep going until the
//  goal is met (`satisfied`), nudge and continue if it isn't yet (`unsatisfied`),
//  or stop early on a real blocker (`blocked`).
//

import Foundation

/// Outcome of a completion check supplied via `AgentCallbacks.verifyCompletion`.
public enum GoalVerdict: Sendable, Equatable {
    /// The goal is met — the agent may stop and return its answer.
    case satisfied
    /// Not done yet. `reason` is fed back to the model as a nudge and the loop
    /// continues (bounded by `AgentConfig.maxVerificationRetries` and `maxTurns`).
    case unsatisfied(reason: String)
    /// A real blocker the agent can't get past (e.g. missing permission, an
    /// impossible request). The loop stops and surfaces `reason` instead of
    /// burning turns retrying.
    case blocked(reason: String)
}
