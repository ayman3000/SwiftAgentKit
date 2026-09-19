//
//  AppleAppTools.swift
//  SwiftAgentKitMac
//
//  The Apple-apps integration as one list, chosen per app by the host.
//

#if os(macOS)
import Foundation
import SwiftAgentKit

public struct AppleApps: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let mail      = AppleApps(rawValue: 1 << 0)
    public static let calendar  = AppleApps(rawValue: 1 << 1)
    public static let reminders = AppleApps(rawValue: 1 << 2)
    public static let notes     = AppleApps(rawValue: 1 << 3)
    public static let contacts  = AppleApps(rawValue: 1 << 4)
    public static let all: AppleApps = [.mail, .calendar, .reminders, .notes, .contacts]
}

/// Every tool for the apps the host turned on. Reads are unconfirmed; every
/// write asks; sending mail asks even in autonomous mode.
public func makeAppleAppTools(_ apps: AppleApps,
                              runner: any AppleScripting = NSAppleScriptRunner(),
                              events: any EventStoring = EKStore(),
                              contacts: any ContactsStoring = CNStore()) -> [any AgentTool] {
    var tools: [any AgentTool] = []
    if apps.contains(.mail) {
        tools += [MailInboxTool(runner: runner), MailSearchTool(runner: runner), MailReadTool(runner: runner),
                  MailDraftTool(runner: runner), MailSendTool(runner: runner)]
    }
    if apps.contains(.notes) {
        tools += [NotesListTool(runner: runner), NotesSearchTool(runner: runner), NotesReadTool(runner: runner), NotesCreateTool(runner: runner)]
    }
    if apps.contains(.calendar) {
        tools += [CalendarEventsTool(store: events), CalendarCreateEventTool(store: events)]
    }
    if apps.contains(.reminders) {
        tools += [RemindersListTool(store: events), RemindersAddTool(store: events), RemindersCompleteTool(store: events)]
    }
    if apps.contains(.contacts) {
        tools += [ContactsSearchTool(store: contacts)]
    }
    return tools
}

/// System-prompt guidance the host appends when any Apple app is on.
public func appleAppsPromptGuidance(_ apps: AppleApps) -> String {
    var names: [String] = []
    if apps.contains(.mail) { names.append("Mail (mail_inbox, mail_search, mail_read, mail_draft, mail_send)") }
    if apps.contains(.calendar) { names.append("Calendar (calendar_events, calendar_create_event)") }
    if apps.contains(.reminders) { names.append("Reminders (reminders_list, reminders_add, reminders_complete)") }
    if apps.contains(.notes) { names.append("Notes (notes_list, notes_search, notes_read, notes_create)") }
    if apps.contains(.contacts) { names.append("Contacts (contacts_search)") }
    guard !names.isEmpty else { return "" }
    return """
    - The user's Mac apps: \(names.joined(separator: "; ")). Use these tools — never drive \
    these apps' windows with mac_* or the shell for the same job. Read before you write; keep \
    reads bounded (a time window, a limit). Dates are ISO 8601 in the Mac's time zone. Every \
    write asks the user first. Sending mail asks every time: prefer mail_draft, which opens the \
    message in Mail for the user to send, unless the user explicitly said to send.
    """
}
#endif
