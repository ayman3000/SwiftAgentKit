#if os(macOS)
import Foundation
import SwiftAgentKit
import LLMProviderKit

// MARK: - SimScreenshotTool

public struct SimScreenshotTool: AgentTool {
    public let name = "sim_screenshot"
    public var isReadOnly: Bool { true }
    public let description = """
    Screenshot the iOS SIMULATOR screen as an image. Simulator only — it cannot see \
    Mac apps; for a Mac app read the window with mac_ui instead. Slower than sim_ui and \
    needs a vision-capable model — use only when layout/appearance matters or sim_ui is ambiguous.
    """
    public let parameters = ToolParameters(properties: [:], required: [])
    let client: any SimDriving
    public init(client: any SimDriving, session: SimSession) { self.client = client }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        do {
            let png = try await client.screenshot()
            return .success(toolCallId: "", toolName: name, result: "Screenshot captured.",
                            images: [LLMImage(data: png, mimeType: "image/png")])
        } catch {
            return .error(toolCallId: "", toolName: name, message: "screenshot failed: \(error.localizedDescription)")
        }
    }
}
#endif
