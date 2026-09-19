//
//  AppleCalendarTools.swift
//  SwiftAgentKitMac
//
//  Calendar and Reminders through EventKit, behind one small protocol so the
//  tools are tested against a fake store. The real store asks macOS for
//  access the first time; the host declares the usage strings.
//

#if os(macOS)
import EventKit
import Foundation
import SwiftAgentKit

public struct CalendarEvent: Equatable, Sendable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let allDay: Bool
    public let calendar: String
    public let location: String?
    public let notes: String?
    public init(id: String, title: String, start: Date, end: Date, allDay: Bool, calendar: String, location: String?, notes: String?) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.allDay = allDay
        self.calendar = calendar; self.location = location; self.notes = notes
    }
    /// Enough of the identifier to name this event in a later call.
    public var shortID: String { String(id.prefix(8)) }
    public var line: String {
        var s = "[\(shortID)] \(AppleDates.span(start, end, allDay: allDay))  \(title)  (\(calendar))"
        if let location, !location.isEmpty { s += "  @ \(location)" }
        return s
    }
}

public struct ReminderItem: Equatable, Sendable {
    public let id: String
    public let title: String
    public let due: Date?
    public let list: String
    public let completed: Bool
    public let notes: String?
    public init(id: String, title: String, due: Date?, list: String, completed: Bool, notes: String?) {
        self.id = id; self.title = title; self.due = due; self.list = list; self.completed = completed; self.notes = notes
    }
    public var line: String {
        "[\(id.prefix(8))] \(completed ? "☑" : "☐") \(title)" + (due.map { "  due \(AppleDates.string($0))" } ?? "") + "  (\(list))"
    }
}

public enum AppleAccess: Equatable, Sendable { case granted, denied, notAsked }

/// What the tools need from EventKit. `EKStore` is the real one.
public protocol EventStoring: Sendable {
    func requestEvents() async -> Bool
    func requestReminders() async -> Bool
    func calendars() -> [String]
    func events(from: Date, to: Date, calendars: [String]?) -> [CalendarEvent]
    func createEvent(title: String, start: Date, end: Date, allDay: Bool, calendar: String?, location: String?, notes: String?) throws -> CalendarEvent
    func deleteEvent(id: String) throws -> CalendarEvent
    func reminderLists() -> [String]
    func reminders(list: String?, includeCompleted: Bool) async -> [ReminderItem]
    func addReminder(title: String, due: Date?, list: String?, notes: String?) throws -> ReminderItem
    func completeReminder(id: String) async throws -> ReminderItem
    func deleteReminder(id: String) async throws -> ReminderItem
}

public final class EKStore: EventStoring, @unchecked Sendable {
    private let store = EKEventStore()
    public init() {}

    public static func eventsAccess() -> AppleAccess { access(EKEventStore.authorizationStatus(for: .event)) }
    public static func remindersAccess() -> AppleAccess { access(EKEventStore.authorizationStatus(for: .reminder)) }
    private static func access(_ s: EKAuthorizationStatus) -> AppleAccess {
        if #available(macOS 14, *), s == .fullAccess { return .granted }
        switch s {
        case .authorized: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    public func requestEvents() async -> Bool {
        if Self.eventsAccess() == .granted { return true }
        if #available(macOS 14, *) { return (try? await store.requestFullAccessToEvents()) ?? false }
        return (try? await store.requestAccess(to: .event)) ?? false
    }
    public func requestReminders() async -> Bool {
        if Self.remindersAccess() == .granted { return true }
        if #available(macOS 14, *) { return (try? await store.requestFullAccessToReminders()) ?? false }
        return (try? await store.requestAccess(to: .reminder)) ?? false
    }

    public func calendars() -> [String] { store.calendars(for: .event).map(\.title).sorted() }

    public func events(from: Date, to: Date, calendars names: [String]?) -> [CalendarEvent] {
        let cals = names.map { wanted in store.calendars(for: .event).filter { wanted.contains($0.title) } }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: cals)
        return store.events(matching: predicate).map { e in
            CalendarEvent(id: e.eventIdentifier ?? "", title: e.title ?? "", start: e.startDate, end: e.endDate,
                          allDay: e.isAllDay, calendar: e.calendar.title, location: e.location, notes: e.notes)
        }.sorted { $0.start < $1.start }
    }

    public func createEvent(title: String, start: Date, end: Date, allDay: Bool, calendar: String?, location: String?, notes: String?) throws -> CalendarEvent {
        let e = EKEvent(eventStore: store)
        e.title = title; e.startDate = start; e.endDate = end; e.isAllDay = allDay
        e.location = location; e.notes = notes
        e.calendar = calendar.flatMap { name in store.calendars(for: .event).first { $0.title == name } } ?? store.defaultCalendarForNewEvents
        try store.save(e, span: .thisEvent, commit: true)
        return CalendarEvent(id: e.eventIdentifier ?? "", title: title, start: start, end: end, allDay: allDay,
                             calendar: e.calendar.title, location: location, notes: notes)
    }

    /// Deleting needs the event first; an id from a list is a prefix, so fall
    /// back to a search across a year either side when the exact id misses.
    public func deleteEvent(id: String) throws -> CalendarEvent {
        let found = store.event(withIdentifier: id) ?? {
            let predicate = store.predicateForEvents(withStart: Date().addingTimeInterval(-365 * 86_400),
                                                     end: Date().addingTimeInterval(365 * 86_400), calendars: nil)
            return store.events(matching: predicate).first { ($0.eventIdentifier ?? "").hasPrefix(id) }
        }()
        guard let e = found else {
            throw NSError(domain: "AppleCalendar", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "No event with id \(id) in the year around today. List the events again and use an id from that list."])
        }
        let snapshot = CalendarEvent(id: e.eventIdentifier ?? id, title: e.title ?? "", start: e.startDate, end: e.endDate,
                                     allDay: e.isAllDay, calendar: e.calendar.title, location: e.location, notes: e.notes)
        try store.remove(e, span: .thisEvent, commit: true)
        return snapshot
    }

    public func reminderLists() -> [String] { store.calendars(for: .reminder).map(\.title).sorted() }

    public func reminders(list: String?, includeCompleted: Bool) async -> [ReminderItem] {
        let cals = list.map { name in store.calendars(for: .reminder).filter { $0.title == name } }
        let predicate = includeCompleted ? store.predicateForReminders(in: cals)
                                         : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: cals)
        // Map inside the callback: EKReminder is not Sendable, ReminderItem is.
        let items: [ReminderItem] = await withCheckedContinuation { c in
            store.fetchReminders(matching: predicate) { found in
                c.resume(returning: (found ?? []).map { r in
                    ReminderItem(id: r.calendarItemIdentifier, title: r.title ?? "",
                                 due: r.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                                 list: r.calendar.title, completed: r.isCompleted, notes: r.notes)
                })
            }
        }
        return items.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    public func addReminder(title: String, due: Date?, list: String?, notes: String?) throws -> ReminderItem {
        let r = EKReminder(eventStore: store)
        r.title = title; r.notes = notes
        if let due { r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due) }
        r.calendar = list.flatMap { name in store.calendars(for: .reminder).first { $0.title == name } } ?? store.defaultCalendarForNewReminders()
        try store.save(r, commit: true)
        return ReminderItem(id: r.calendarItemIdentifier, title: title, due: due, list: r.calendar.title, completed: false, notes: notes)
    }

    public func deleteReminder(id: String) async throws -> ReminderItem {
        let all = await reminders(list: nil, includeCompleted: true)
        guard let match = all.first(where: { $0.id == id || $0.id.hasPrefix(id) }),
              let r = store.calendarItem(withIdentifier: match.id) as? EKReminder else {
            throw NSError(domain: "AppleReminders", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "No reminder with id \(id). List the reminders again and use an id from that list."])
        }
        try store.remove(r, commit: true)
        return match
    }

    public func completeReminder(id: String) async throws -> ReminderItem {
        let all = await reminders(list: nil, includeCompleted: false)
        guard let match = all.first(where: { $0.id == id || $0.id.hasPrefix(id) }),
              let r = store.calendarItem(withIdentifier: match.id) as? EKReminder else {
            throw NSError(domain: "AppleReminders", code: 404, userInfo: [NSLocalizedDescriptionKey: "No open reminder with id \(id)."])
        }
        r.isCompleted = true
        try store.save(r, commit: true)
        return ReminderItem(id: r.calendarItemIdentifier, title: r.title ?? "", due: match.due, list: r.calendar.title, completed: true, notes: r.notes)
    }
}

// MARK: - Calendar tools

public struct CalendarEventsTool: AgentTool {
    public let name = "calendar_events"
    public var isReadOnly: Bool { true }
    public let description = """
    The user's calendar events in a date range, from the Calendar app on this Mac (every account \
    it syncs). Defaults to today through the next 7 days. Dates are ISO 8601 in the Mac's time zone. \
    Also lists the calendar names when asked with `list_calendars`.
    """
    public let parameters = ToolParameters(properties: [
        "from": ToolParameterProperty(type: "string", description: "Start (ISO 8601 or YYYY-MM-DD). Default: now."),
        "to": ToolParameterProperty(type: "string", description: "End (ISO 8601 or YYYY-MM-DD). Default: from + `days`."),
        "days": ToolParameterProperty(type: "integer", description: "Days ahead when `to` is absent (default 7, max 90)."),
        "calendars": ToolParameterProperty(type: "array", description: "Only these calendar names (optional).", itemsType: "string"),
        "list_calendars": ToolParameterProperty(type: "boolean", description: "Also return the calendar names."),
    ], required: [])
    public var inputExamples: [String] { [#"{"days": 1}"#, #"{"from": "2026-09-22", "to": "2026-09-27", "calendars": ["Work"]}"#] }
    let store: any EventStoring
    public init(store: any EventStoring = EKStore()) { self.store = store }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard await store.requestEvents() else {
            return .error(toolCallId: "", toolName: name, message: "macOS has not allowed Naseem to read the calendar. Allow it in System Settings ▸ Privacy & Security ▸ Calendars.")
        }
        let now = Date()
        let from = stringArg(parameters["from"]).flatMap(AppleDates.parse) ?? now
        let days = min(max(intArg(parameters["days"]) ?? 7, 1), 90)
        var to = stringArg(parameters["to"]).flatMap(AppleDates.parse) ?? from.addingTimeInterval(Double(days) * 86_400)
        if stringArg(parameters["to"]).map({ $0.count == 10 }) == true { to = to.addingTimeInterval(86_400) }   // a bare day means through that day
        let names = stringList(parameters["calendars"])
        let events = store.events(from: from, to: to, calendars: names.isEmpty ? nil : names)
        var out = events.isEmpty ? "No events between \(AppleDates.string(from)) and \(AppleDates.string(to))."
                                 : "\(events.count) event(s):\n" + events.map(\.line).joined(separator: "\n")
        if (parameters["list_calendars"] as? Bool) == true { out += "\n\nCalendars: " + store.calendars().joined(separator: ", ") }
        return .success(toolCallId: "", toolName: name, result: out)
    }
}

public struct CalendarCreateEventTool: AgentTool {
    public let name = "calendar_create_event"
    public let description = """
    Create an event in the user's Calendar: a meeting, an appointment, a trip — something that \
    occupies a span of time. For a task the user wants to be reminded about ("remind me to…"), \
    use reminders_add instead; a calendar event is not a reminder. Confirmed by the user. Dates \
    ISO 8601 in the Mac's time zone; omit `end` for one hour.
    """
    public let parameters = ToolParameters(properties: [
        "title": ToolParameterProperty(type: "string", description: "Event title."),
        "start": ToolParameterProperty(type: "string", description: "Start, ISO 8601 (or YYYY-MM-DD with all_day)."),
        "end": ToolParameterProperty(type: "string", description: "End, ISO 8601 (default start + 1 hour)."),
        "all_day": ToolParameterProperty(type: "boolean", description: "All-day event (default false)."),
        "calendar": ToolParameterProperty(type: "string", description: "Calendar name (default: the default calendar)."),
        "location": ToolParameterProperty(type: "string", description: "Location (optional)."),
        "notes": ToolParameterProperty(type: "string", description: "Notes (optional)."),
    ], required: ["title", "start"])
    public var requiresConfirmation: Bool { true }
    public var inputExamples: [String] { [#"{"title": "Design review", "start": "2026-09-22T15:00:00+03:00", "end": "2026-09-22T16:00:00+03:00", "calendar": "Work"}"#] }
    let store: any EventStoring
    public init(store: any EventStoring = EKStore()) { self.store = store }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard await store.requestEvents() else {
            return .error(toolCallId: "", toolName: name, message: "macOS has not allowed Naseem to use the calendar. Allow it in System Settings ▸ Privacy & Security ▸ Calendars.")
        }
        guard let title = stringArg(parameters["title"]), let start = stringArg(parameters["start"]).flatMap(AppleDates.parse) else {
            return .error(toolCallId: "", toolName: name, message: "title and a valid ISO 8601 start are required.")
        }
        let allDay = (parameters["all_day"] as? Bool) ?? false
        let end = stringArg(parameters["end"]).flatMap(AppleDates.parse) ?? start.addingTimeInterval(allDay ? 86_400 : 3_600)
        guard end > start else { return .error(toolCallId: "", toolName: name, message: "end must be after start.") }
        let e = try store.createEvent(title: title, start: start, end: end, allDay: allDay,
                                      calendar: stringArg(parameters["calendar"]), location: stringArg(parameters["location"]),
                                      notes: parameters["notes"] as? String)
        return .success(toolCallId: "", toolName: name, result: "Created: " + e.line)
    }
}

// MARK: - Reminders tools

/// Deleting the user's own data: always asks, autonomy or not.
public struct CalendarDeleteEventTool: AgentTool {
    public let name = "calendar_delete_event"
    public let description = """
    Delete an event from the user's Calendar, by the id shown in square brackets by \
    calendar_events. There is no undo, so list the events first and delete the one the user \
    named — never guess an id. The user is asked to confirm every deletion.
    """
    public let parameters = ToolParameters(properties: [
        "id": ToolParameterProperty(type: "string", description: "Event id from calendar_events (the bracketed prefix is enough)."),
    ], required: ["id"])
    public var requiresConfirmation: Bool { true }
    public var requiresConfirmationEvenWhenAutonomous: Bool { true }
    public var inputExamples: [String] { [#"{"id": "A1B2C3D4"}"#] }
    let store: any EventStoring
    public init(store: any EventStoring = EKStore()) { self.store = store }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard await store.requestEvents() else {
            return .error(toolCallId: "", toolName: name, message: "macOS has not allowed Naseem to use the calendar. Allow it in System Settings ▸ Privacy & Security ▸ Calendars.")
        }
        guard let id = stringArg(parameters["id"]) else { return .error(toolCallId: "", toolName: name, message: "id is required.") }
        let e = try store.deleteEvent(id: id)
        return .success(toolCallId: "", toolName: name, result: "Deleted: " + e.line)
    }
}

public struct RemindersListTool: AgentTool {
    public let name = "reminders_list"
    public var isReadOnly: Bool { true }
    public let description = "The user's open reminders (or one list's), soonest due first, from the Reminders app. Also names the lists."
    public let parameters = ToolParameters(properties: [
        "list": ToolParameterProperty(type: "string", description: "A list name (optional)."),
        "include_completed": ToolParameterProperty(type: "boolean", description: "Include completed reminders (default false)."),
        "limit": ToolParameterProperty(type: "integer", description: "Most reminders to return (default 50, max 200)."),
    ], required: [])
    public var inputExamples: [String] { [#"{}"#, #"{"list": "Groceries"}"#] }
    let store: any EventStoring
    public init(store: any EventStoring = EKStore()) { self.store = store }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard await store.requestReminders() else {
            return .error(toolCallId: "", toolName: name, message: "macOS has not allowed Naseem to read reminders. Allow it in System Settings ▸ Privacy & Security ▸ Reminders.")
        }
        let limit = min(max(intArg(parameters["limit"]) ?? 50, 1), 200)
        let items = Array(await store.reminders(list: stringArg(parameters["list"]), includeCompleted: (parameters["include_completed"] as? Bool) ?? false).prefix(limit))
        let lists = "Lists: " + store.reminderLists().joined(separator: ", ")
        let body = items.isEmpty ? "No open reminders." : items.map(\.line).joined(separator: "\n")
        return .success(toolCallId: "", toolName: name, result: lists + "\n\n" + body)
    }
}

public struct RemindersAddTool: AgentTool {
    public let name = "reminders_add"
    public let description = """
    Add a reminder to the Reminders app — this is what "remind me to…", "add a reminder" and \
    "don't let me forget" mean, with or without a time. Optionally a due date (ISO 8601) and a \
    list name. For a meeting or appointment that occupies time, use calendar_create_event \
    instead. Confirmed by the user.
    """
    public let parameters = ToolParameters(properties: [
        "title": ToolParameterProperty(type: "string", description: "What to remember."),
        "due": ToolParameterProperty(type: "string", description: "Due date/time, ISO 8601 (optional)."),
        "list": ToolParameterProperty(type: "string", description: "List name (default: the default list)."),
        "notes": ToolParameterProperty(type: "string", description: "Notes (optional)."),
    ], required: ["title"])
    public var requiresConfirmation: Bool { true }
    public var inputExamples: [String] { [#"{"title": "Send the invoice to Sara", "due": "2026-09-22T09:00:00+03:00"}"#] }
    let store: any EventStoring
    public init(store: any EventStoring = EKStore()) { self.store = store }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard await store.requestReminders() else {
            return .error(toolCallId: "", toolName: name, message: "macOS has not allowed Naseem to use reminders. Allow it in System Settings ▸ Privacy & Security ▸ Reminders.")
        }
        guard let title = stringArg(parameters["title"]) else { return .error(toolCallId: "", toolName: name, message: "title is required.") }
        let due = stringArg(parameters["due"]).flatMap(AppleDates.parse)
        let r = try store.addReminder(title: title, due: due, list: stringArg(parameters["list"]), notes: parameters["notes"] as? String)
        return .success(toolCallId: "", toolName: name, result: "Added: " + r.line)
    }
}

public struct RemindersDeleteTool: AgentTool {
    public let name = "reminders_delete"
    public let description = """
    Delete a reminder, by the id from reminders_list. There is no undo — if the user only means \
    it is done, use reminders_complete instead, which keeps it. The user is asked to confirm \
    every deletion.
    """
    public let parameters = ToolParameters(properties: [
        "id": ToolParameterProperty(type: "string", description: "Reminder id (the prefix shown in the list is enough)."),
    ], required: ["id"])
    public var requiresConfirmation: Bool { true }
    public var requiresConfirmationEvenWhenAutonomous: Bool { true }
    public var inputExamples: [String] { [#"{"id": "3F2A9C10"}"#] }
    let store: any EventStoring
    public init(store: any EventStoring = EKStore()) { self.store = store }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard await store.requestReminders() else {
            return .error(toolCallId: "", toolName: name, message: "macOS has not allowed Naseem to use reminders. Allow it in System Settings ▸ Privacy & Security ▸ Reminders.")
        }
        guard let id = stringArg(parameters["id"]) else { return .error(toolCallId: "", toolName: name, message: "id is required.") }
        let r = try await store.deleteReminder(id: id)
        return .success(toolCallId: "", toolName: name, result: "Deleted: " + r.line)
    }
}

public struct RemindersCompleteTool: AgentTool {
    public let name = "reminders_complete"
    public let description = "Mark a reminder done, by the id from reminders_list. Confirmed by the user."
    public let parameters = ToolParameters(properties: [
        "id": ToolParameterProperty(type: "string", description: "Reminder id (the prefix shown in the list is enough)."),
    ], required: ["id"])
    public var requiresConfirmation: Bool { true }
    public var inputExamples: [String] { [#"{"id": "3F2A9C10"}"#] }
    let store: any EventStoring
    public init(store: any EventStoring = EKStore()) { self.store = store }

    public func execute(parameters: [String: Any]) async throws -> AgentToolResult {
        guard await store.requestReminders() else {
            return .error(toolCallId: "", toolName: name, message: "macOS has not allowed Naseem to use reminders. Allow it in System Settings ▸ Privacy & Security ▸ Reminders.")
        }
        guard let id = stringArg(parameters["id"]) else { return .error(toolCallId: "", toolName: name, message: "id is required.") }
        let r = try await store.completeReminder(id: id)
        return .success(toolCallId: "", toolName: name, result: "Done: " + r.line)
    }
}
#endif
