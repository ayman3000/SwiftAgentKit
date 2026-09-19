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

/// System-prompt guidance the host appends when any Apple app is on. It names
/// the apps that are OFF as well: a model with no reminders tool otherwise
/// invents a substitute (a calendar event "as a reminder") or an excuse about
/// profiles, and the user is left thinking Naseem is broken rather than that
/// one switch is off.
public func appleAppsPromptGuidance(_ apps: AppleApps) -> String {
    let all: [(AppleApps, String, String)] = [
        (.mail, "Mail", "mail_inbox, mail_search, mail_read, mail_draft, mail_send"),
        (.calendar, "Calendar", "calendar_events, calendar_create_event"),
        (.reminders, "Reminders", "reminders_list, reminders_add, reminders_complete"),
        (.notes, "Notes", "notes_list, notes_search, notes_read, notes_create"),
        (.contacts, "Contacts", "contacts_search"),
    ]
    let on = all.filter { apps.contains($0.0) }.map { "\($0.1) (\($0.2))" }
    guard !on.isEmpty else { return "" }
    let off = all.filter { !apps.contains($0.0) }.map(\.1)

    var text = """
    - The user's Mac apps: \(on.joined(separator: "; ")). These tools are available in EVERY \
    profile — never tell the user to switch profile to reach them, and never drive these apps' \
    windows with mac_* or the shell for the same job. Read before you write; keep reads bounded \
    (a time window, a limit). Dates are ISO 8601 in the Mac's time zone. Every write asks the \
    user first. Sending mail asks every time: prefer mail_draft, which opens the message in Mail \
    for the user to send, unless the user explicitly said to send.
    """
    if apps.contains(.reminders) && apps.contains(.calendar) {
        text += """
        \n    - Reminder or event: "remind me", "add a reminder", "don't let me forget", a task \
        with no duration → reminders_add. A meeting, appointment or anything that occupies a span \
        of time → calendar_create_event. Do not put a reminder in the calendar, or an appointment \
        in Reminders, because the other one is easier to reach.
        """
    }
    if !off.isEmpty {
        text += """
        \n    - NOT turned on: \(off.joined(separator: ", ")). If the user asks for something one \
        of these handles, say plainly that it is off and that they can turn it on in Settings ▸ \
        Integrations ▸ Apple apps. Never substitute a different app for it (no calendar events \
        standing in for reminders), and never blame the profile or the model — one switch is off, \
        that is all.
        """
    }
    return text
}

#endif
