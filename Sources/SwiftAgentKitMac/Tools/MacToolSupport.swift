#if os(macOS)
import Foundation
import SwiftAgentKit

// MARK: - MacTarget parameter parsing

extension MacTarget {
    /// Build a MacTarget from tool parameters (ref+generation, title, or identifier).
    static func from(_ p: [String: Any]) -> MacTarget {
        MacTarget(
            ref: p["ref"] as? String,
            title: p["title"] as? String,
            identifier: p["identifier"] as? String,
            generation: p["generation"] as? Int
        )
    }
}

// MARK: - AllowlistGuard

/// Security boundary: resolves and validates a bundle ID against the conversation allowlist.
///
/// Every tool (reads included) must pass through this guard before touching the AX driver.
/// nil/empty allowlist always denies; missing bundle_id is an error; not-in-allowlist is denied.
enum AllowlistGuard {

    enum GuardResult {
        case success(String)
        case failure(AgentToolResult)
    }

    /// Resolve the bundle_id from parameters and verify it is in the allowlist.
    ///
    /// - Returns: `.success(bundleId)` if allowed, `.failure(AgentToolResult)` with a
    ///   model-facing error message otherwise.
    static func resolve(
        _ p: [String: Any],
        allowlist: Set<String>,
        toolName: String
    ) -> GuardResult {
        guard let bundleId = p["bundle_id"] as? String, !bundleId.isEmpty else {
            return .failure(.error(
                toolCallId: "",
                toolName: toolName,
                message: "\(toolName) requires `bundle_id` (see mac_apps for allowed apps)."))
        }
        guard !allowlist.isEmpty, allowlist.contains(bundleId) else {
            return .failure(.error(
                toolCallId: "",
                toolName: toolName,
                message: "App \(bundleId) is not permitted in this conversation. Ask the user to allow it."))
        }
        return .success(bundleId)
    }
}

// MARK: - makeMacTools

/// Returns all 7 mac_* AgentTools wired to the given AX client and allowlist provider.
public func makeMacTools(
    allowlistProvider: @escaping @Sendable () -> Set<String>,
    client: any AXDriving
) -> [any AgentTool] {
    [
        MacAppsTool(client: client, allowlistProvider: allowlistProvider),
        MacUITool(client: client, allowlistProvider: allowlistProvider),
        MacClickTool(client: client, allowlistProvider: allowlistProvider),
        MacTypeTool(client: client, allowlistProvider: allowlistProvider),
        MacKeyTool(client: client, allowlistProvider: allowlistProvider),
        MacWaitTool(client: client, allowlistProvider: allowlistProvider),
        MacLaunchTool(client: client, allowlistProvider: allowlistProvider),
    ]
}

// MARK: - Shared trust check helper

/// Returns a model-facing accessibility error result, or nil if trusted.
func accessibilityError(toolName: String, client: any AXDriving) -> AgentToolResult? {
    guard client.isTrusted() else {
        return .error(
            toolCallId: "",
            toolName: toolName,
            message: "Accessibility permission not granted. Enable Naseem under System Settings → Privacy & Security → Accessibility.")
    }
    return nil
}

#endif
