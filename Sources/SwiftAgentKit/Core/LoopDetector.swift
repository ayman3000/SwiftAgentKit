import Foundation

/// Thresholds for the ReAct-loop no-progress guard.
public struct LoopDetectionConfig: Sendable, Equatable {
    /// How many recent tool-call signatures are considered.
    public var windowSize: Int
    /// Occurrences of one signature within the window that trigger a corrective nudge.
    public var nudgeThreshold: Int
    /// Occurrences that trigger a graceful stop.
    public var stopThreshold: Int

    public init(windowSize: Int = 6, nudgeThreshold: Int = 3, stopThreshold: Int = 5) {
        self.windowSize = windowSize
        self.nudgeThreshold = nudgeThreshold
        self.stopThreshold = stopThreshold
    }

    public static let `default` = LoopDetectionConfig()
}

/// What the loop should do after recording a turn's tool calls.
public enum LoopAction: Sendable, Equatable {
    case none
    case nudge(signature: String, count: Int)
    case stop(signature: String, count: Int)
}

/// Detects a stalled agent: the same (tool + args) signature repeating within a
/// recent window. Pure and deterministic — no LLM, no I/O.
final class LoopDetector {
    private let config: LoopDetectionConfig
    private var history: [String] = []
    private var nudged: Set<String> = []

    init(config: LoopDetectionConfig) { self.config = config }

    /// Canonical signature: tool name + sorted-keys JSON of args (no args → name).
    static func signature(name: String, arguments: [String: AnyCodable]) -> String {
        guard !arguments.isEmpty else { return name }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(arguments), let json = String(data: data, encoding: .utf8) {
            return name + ":" + json
        }
        // Deterministic value-preserving fallback: includes key+value pairs so
        // distinct argument values still produce distinct signatures (unlike a
        // keys-only join). Reached only if JSONEncoder somehow fails, which
        // AnyCodable's implementation does not do in practice.
        let fallback = arguments.keys.sorted().map { "\($0)=\(String(describing: arguments[$0]!))" }.joined(separator: ",")
        return name + ":" + fallback
    }

    /// Record one turn's tool-call signatures (in call order) and decide the action.
    /// `.stop` wins over `.nudge` when both qualify in the same turn; each signature
    /// nudges at most once before it later escalates to stop.
    func record(_ signatures: [String]) -> LoopAction {
        history.append(contentsOf: signatures)
        if history.count > config.windowSize {
            history.removeFirst(history.count - config.windowSize)
        }
        let window = history.suffix(config.windowSize)

        var pendingNudge: LoopAction?
        for sig in signatures {
            let count = window.filter { $0 == sig }.count
            if count >= config.stopThreshold {
                return .stop(signature: sig, count: count)   // stop beats any nudge
            }
            if count >= config.nudgeThreshold, !nudged.contains(sig), pendingNudge == nil {
                nudged.insert(sig)
                pendingNudge = .nudge(signature: sig, count: count)
            }
        }
        return pendingNudge ?? .none
    }
}
