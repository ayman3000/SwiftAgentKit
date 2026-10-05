//
//  RememberTool.swift
//  SwiftAgentKit
//
//  `remember` notes something worth keeping. It does not write memory: the
//  note waits in the run's MemoryInbox and the app files it after the run,
//  where one decision covers where it belongs, what it merges with and
//  whether it is worth keeping at all.
//

import Foundation

public final class RememberTool: AgentTool, @unchecked Sendable {

    public let name = "remember"

    public let description = """
    Note something worth remembering beyond this conversation: who the user \
    is, how they like answers, or a lasting decision, convention or path for \
    the work. Notes are filed after your reply by a separate step that decides \
    where each one belongs (about the user, this project, or everywhere), \
    merges it with what is already known and drops what is not worth keeping, \
    so just write the note in one or two plain sentences. Do NOT note one-off \
    task details (files you just made, results of this run). Don't ask \
    permission first.
    """

    public let parameters = ToolParameters(
        properties: [
            "text": ToolParameterProperty(
                type: "string",
                description: "The note, in plain words."
            ),
            "about": ToolParameterProperty(
                type: "string",
                description: "Optional hint: \"me\" (the user), \"project\" (the work in front of you) or \"general\".",
                enum: ["me", "project", "general"]
            )
        ],
        required: ["text"]
    )

    /// Longest note accepted, in characters.
    public static let maxTextLength = 1000

    private let inbox: MemoryInbox
    private let activeProject: String?

    public init(inbox: MemoryInbox, activeProject: String? = nil) {
        self.inbox = inbox
        self.activeProject = activeProject
    }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        var text = ((parameters["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, let content = (parameters["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !content.isEmpty {
            // A model that still uses the old title/content shape.
            let title = ((parameters["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            text = title.isEmpty ? content : "\(title): \(content)"
        }
        guard !text.isEmpty else {
            return .error(toolCallId: "", toolName: name, message: "Error: `text` is required.")
        }
        guard text.count <= Self.maxTextLength else {
            return .error(toolCallId: "", toolName: name,
                          message: "Error: `text` is \(text.count) characters; the most is \(Self.maxTextLength). Write the note in one or two plain sentences.")
        }
        let about = (parameters["about"] as? String).flatMap { MemoryNote.About(rawValue: $0.lowercased()) }
        await inbox.add(MemoryNote(text: text, about: about, project: activeProject))
        return .success(toolCallId: "", toolName: name, result: "Noted; it will be filed after this reply.")
    }
}
