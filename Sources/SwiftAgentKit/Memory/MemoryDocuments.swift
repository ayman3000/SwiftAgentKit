//
//  MemoryDocuments.swift
//  SwiftAgentKit
//
//  The memory files' text formats as pure functions: USER.md keys, AGENT.md
//  sections, fact files. The store calls these for every write, so the rules
//  hold whoever writes: one line per USER.md key, each AGENT.md section once,
//  one heading per fact.
//

import Foundation

/// A section of AGENT.md — the agent's identity and mission.
public enum AgentProfileSection: String, Sendable, Codable, CaseIterable {
    case identity, mission, tone, principles

    /// The `## ` heading text in AGENT.md.
    public var heading: String {
        switch self {
        case .identity: return "Identity"
        case .mission: return "Mission"
        case .tone: return "Tone"
        case .principles: return "Principles the user added"
        }
    }
}

public enum MemoryDocuments {

    /// The AGENT.md the store seeded before sections existed. A file that
    /// still holds exactly this was never edited, so replacing it loses nothing.
    public static let legacyKitDefaultAgentProfile = """
    # Agent Soul

    You are a helpful, capable agent. Use your tools proactively. Remember what
    matters about the user and their projects. Act with care on their data.
    """

    /// The generic AGENT.md for apps that do not supply their own.
    public static let defaultAgentProfile = """
    # Agent

    ## Identity
    Name: Agent

    ## Mission
    A helpful, capable agent. Use your tools proactively and act with care on the user's data.

    ## Tone
    Plain and concise.

    ## Principles the user added

    """

    // MARK: - USER.md — one `- **Key:** value` line per key

    public static func userKeys(_ doc: String) -> [(key: String, value: String)] {
        doc.components(separatedBy: "\n").compactMap(parseUserLine)
    }

    public static func userValue(_ key: String, in doc: String) -> String? {
        userKeys(doc).first { $0.key.lowercased() == key.lowercased() }?.value
    }

    /// Writing an existing key replaces its line (keeping the existing
    /// spelling of the key) and removes any later copies; a new key is
    /// appended.
    public static func settingUserKey(_ key: String, value: String, in doc: String) -> String {
        let key = oneLine(key)
        let value = oneLine(value)
        var lines = doc.isEmpty ? ["# User", ""] : doc.components(separatedBy: "\n")
        let matches = lines.indices.filter { parseUserLine(lines[$0])?.key.lowercased() == key.lowercased() }
        if let first = matches.first {
            let existingKey = parseUserLine(lines[first])?.key ?? key
            for index in matches.dropFirst().reversed() { lines.remove(at: index) }
            lines[first] = "- **\(existingKey):** \(value)"
        } else {
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            if lines.count == 1 { lines.append("") }   // a lone heading keeps its blank line
            lines.append("- **\(key):** \(value)")
        }
        return normalized(lines.joined(separator: "\n"))
    }

    public static func removingUserKey(_ key: String, in doc: String) -> String {
        let lines = doc.components(separatedBy: "\n")
            .filter { parseUserLine($0)?.key.lowercased() != key.lowercased() }
        return normalized(lines.joined(separator: "\n"))
    }

    static func parseUserLine(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- **") else { return nil }
        let rest = trimmed.dropFirst(4)
        guard let close = rest.range(of: ":**") else { return nil }
        let key = rest[..<close.lowerBound].trimmingCharacters(in: .whitespaces)
        let value = rest[close.upperBound...].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : (key, value)
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: - AGENT.md — `## <section>` blocks

    /// True when every section heading is present.
    public static func isStructuredAgentProfile(_ doc: String) -> Bool {
        let lines = doc.components(separatedBy: "\n")
        return AgentProfileSection.allCases.allSatisfy { section in lines.contains { isHeading($0, section) } }
    }

    /// The text under a section's heading, trimmed; nil when the heading is absent.
    public static func agentSection(_ section: AgentProfileSection, in doc: String) -> String? {
        let lines = doc.components(separatedBy: "\n")
        guard let heading = lines.firstIndex(where: { isHeading($0, section) }) else { return nil }
        let end = lines[(heading + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.count
        return lines[(heading + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replace one section's text; every other line of the document is kept
    /// as is. A missing section is added at the end.
    public static func replacingAgentSection(_ section: AgentProfileSection, with body: String, in doc: String) -> String {
        var lines = doc.components(separatedBy: "\n")
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let block = ["## \(section.heading)"] + (text.isEmpty ? [] : text.components(separatedBy: "\n")) + [""]
        if let heading = lines.firstIndex(where: { isHeading($0, section) }) {
            let end = lines[(heading + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.count
            lines.replaceSubrange(heading..<end, with: block)
        } else {
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            lines += [""] + block
        }
        return normalized(lines.joined(separator: "\n"))
    }

    /// One edit to one section:
    /// - identity: `Label: value` lines replace the line with the same label; other lines stay.
    /// - mission, tone: the text is replaced.
    /// - principles: each line becomes one bullet, added once.
    public static func editingAgentProfile(_ doc: String, section: AgentProfileSection, change: String) -> String {
        let current = agentSection(section, in: doc) ?? ""
        let body: String
        switch section {
        case .identity:
            body = mergingKeyedLines(change, into: current)
        case .mission, .tone:
            body = change
        case .principles:
            var lines = current.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            for raw in change.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                let bullet = line.hasPrefix("- ") ? line : "- " + line
                if !lines.contains(bullet) { lines.append(bullet) }
            }
            body = lines.joined(separator: "\n")
        }
        return replacingAgentSection(section, with: body, in: doc)
    }

    static func mergingKeyedLines(_ change: String, into body: String) -> String {
        var lines = body.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        for raw in change.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let key = lineKey(line),
               let index = lines.firstIndex(where: { lineKey($0)?.lowercased() == key.lowercased() }) {
                lines[index] = line
            } else if !lines.contains(line) {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func lineKey(_ line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        return key.isEmpty || key.count > 40 ? nil : key
    }

    private static func isHeading(_ line: String, _ section: AgentProfileSection) -> Bool {
        line.trimmingCharacters(in: .whitespaces).lowercased() == "## " + section.heading.lowercased()
    }

    // MARK: - Facts — `# Title`, blank line, body

    public static func factMarkdown(title: String, body: String) -> String {
        "# \(title)\n\n\(factBody(body, title: title))\n"
    }

    /// The body without its own heading. Repeated copies of the same heading
    /// (left by the old Move… bug) are all removed; a different heading is
    /// content and is kept.
    public static func factBody(_ markdown: String, title: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        let heading = "# " + title.lowercased()
        while let first = lines.first {
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            guard trimmed.isEmpty || trimmed.lowercased() == heading else { break }
            lines.removeFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// At most one blank line in a row, one trailing newline.
    public static func normalized(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
