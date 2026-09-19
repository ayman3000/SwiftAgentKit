import XCTest
@testable import SwiftAgentKitMac
import SwiftAgentKit

#if os(macOS)
/// A runner that returns a canned answer and remembers the script it got.
final class MockScript: AppleScripting, @unchecked Sendable {
    var reply = ""
    /// When set, successive calls get successive replies.
    var replies: [String] = []
    var scripts: [String] = []
    var error: Error?
    func run(_ source: String) async throws -> String {
        scripts.append(source)
        if let error { throw error }
        if !replies.isEmpty { return replies.removeFirst() }
        return reply
    }
}

final class MockEvents: EventStoring, @unchecked Sendable {
    var allow = true
    var stored: [CalendarEvent] = []
    var items: [ReminderItem] = []
    var lastCreate: (String, Date, Date)?
    func requestEvents() async -> Bool { allow }
    func requestReminders() async -> Bool { allow }
    func calendars() -> [String] { ["Home", "Work"] }
    func events(from: Date, to: Date, calendars: [String]?) -> [CalendarEvent] {
        stored.filter { $0.start >= from && $0.start < to && (calendars?.contains($0.calendar) ?? true) }
    }
    func createEvent(title: String, start: Date, end: Date, allDay: Bool, calendar: String?, location: String?, notes: String?) throws -> CalendarEvent {
        lastCreate = (title, start, end)
        return CalendarEvent(id: "new", title: title, start: start, end: end, allDay: allDay, calendar: calendar ?? "Home", location: location, notes: notes)
    }
    func reminderLists() -> [String] { ["Reminders", "Groceries"] }
    func reminders(list: String?, includeCompleted: Bool) async -> [ReminderItem] { items.filter { includeCompleted || !$0.completed } }
    func addReminder(title: String, due: Date?, list: String?, notes: String?) throws -> ReminderItem {
        ReminderItem(id: "r9", title: title, due: due, list: list ?? "Reminders", completed: false, notes: notes)
    }
    func completeReminder(id: String) async throws -> ReminderItem {
        guard let r = items.first(where: { $0.id.hasPrefix(id) }) else { throw NSError(domain: "t", code: 404) }
        return ReminderItem(id: r.id, title: r.title, due: r.due, list: r.list, completed: true, notes: r.notes)
    }
}

final class MockContacts: ContactsStoring, @unchecked Sendable {
    var allow = true
    func requestAccess() async -> Bool { allow }
    func search(_ query: String, limit: Int) throws -> [ContactCard] {
        query.lowercased().hasPrefix("sa") ? [ContactCard(name: "Sara Ali", emails: ["sara@example.com"], phones: [], organization: "Acme")] : []
    }
}

final class AppleAppsTests: XCTestCase {
    let fs = String(AppleScriptText.field), rs = String(AppleScriptText.record)

    // MARK: Text plumbing

    func testLiteralEscapesQuotesAndBackslashes() {
        XCTAssertEqual(AppleScriptText.literal(#"say "hi" \ bye"#), #""say \"hi\" \\ bye""#)
    }

    func testRecordsSplitOnControlCharacters() {
        let text = "a\(fs)b\(fs)c\(rs)d\(fs)\(fs)f\(rs)"
        XCTAssertEqual(AppleScriptText.records(text), [["a", "b", "c"], ["d", "", "f"]])
    }

    func testISODatesRoundTripInLocalTime() {
        let d = AppleScriptText.date(fromISO: "2026-09-19T15:30:00")!
        let c = Calendar.current.dateComponents([.hour, .minute, .day], from: d)
        XCTAssertEqual(c.hour, 15); XCTAssertEqual(c.minute, 30); XCTAssertEqual(c.day, 19)
        XCTAssertNotNil(AppleDates.parse("2026-09-19"))
        XCTAssertNotNil(AppleDates.parse("2026-09-19T15:30"))
        XCTAssertNotNil(AppleDates.parse("2026-09-19T15:30:00+03:00"))
        XCTAssertNil(AppleDates.parse("next tuesday"))
    }

    // MARK: Mail

    func testInboxToolParsesAndSortsNewestFirst() async throws {
        let mock = MockScript()
        mock.reply = ["11", "2026-09-19T08:00:00", "Ali <ali@x.com>", "Old", "true", "INBOX", "iCloud"].joined(separator: fs) + rs
                   + ["12", "2026-09-19T09:30:00", "Sara <sara@x.com>", "New one", "false", "INBOX", "Gmail"].joined(separator: fs)
        let result = try await MailInboxTool(runner: mock).execute(parameters: ["hours": 48, "unread_only": true])
        XCTAssertTrue(result.result.contains("2 message(s)"))
        XCTAssertLessThan(result.result.range(of: "New one")!.lowerBound, result.result.range(of: "Old")!.lowerBound)
        XCTAssertTrue(result.result.contains("• Sara"), "unread marker")
        XCTAssertTrue(mock.scripts[0].contains("48 * hours"))
        XCTAssertTrue(mock.scripts[0].contains("read status is false"))
    }

    func testInboxBoundsAreClamped() async throws {
        let mock = MockScript()
        _ = try await MailInboxTool(runner: mock).execute(parameters: ["hours": 99_999])
        XCTAssertTrue(mock.scripts[0].contains("720 * hours"))
    }

    func testMailReadCapsTheBody() async throws {
        let mock = MockScript()
        mock.reply = ["Subj", "a@b.c", "me@x.com", "2026-09-19T09:30:00", String(repeating: "x", count: 5_000)].joined(separator: fs)
        let r = try await MailReadTool(runner: mock).execute(parameters: ["id": "12", "max_chars": 600])
        XCTAssertTrue(r.result.contains("truncated at 600"))
        XCTAssertTrue(r.result.hasPrefix("Subject: Subj"))
    }

    func testMailReadRejectsNonNumericID() async throws {
        let r = try await MailReadTool(runner: MockScript()).execute(parameters: ["id": "abc"])
        XCTAssertTrue(r.isError)
    }

    func testComposeScriptQuotesEverythingAndSendsOnlyWhenAsked() {
        let draft = AppleMailScripts.compose(to: ["a@x.com"], cc: [], subject: "He said \"hi\"", body: "line1\nline2", send: false)
        XCTAssertTrue(draft.contains(#"subject:"He said \"hi\"""#))
        XCTAssertTrue(draft.contains("visible:true"))
        XCTAssertFalse(draft.contains("send msg"))
        let send = AppleMailScripts.compose(to: ["a@x.com"], cc: ["b@x.com"], subject: "s", body: "b", send: true)
        XCTAssertTrue(send.contains("send msg"))
        XCTAssertTrue(send.contains("cc recipient"))
    }

    func testSendAlwaysAsksEvenWhenAutonomousAndDraftDoesNot() {
        XCTAssertTrue(MailSendTool(runner: MockScript()).requiresConfirmation)
        XCTAssertTrue(MailSendTool(runner: MockScript()).requiresConfirmationEvenWhenAutonomous)
        XCTAssertTrue(MailDraftTool(runner: MockScript()).requiresConfirmation)
        XCTAssertFalse(MailDraftTool(runner: MockScript()).requiresConfirmationEvenWhenAutonomous)
        XCTAssertTrue(MailInboxTool(runner: MockScript()).isReadOnly)
    }

    func testSendRequiresARealAddress() async throws {
        let r = try await MailSendTool(runner: MockScript()).execute(parameters: ["to": ["nobody"], "subject": "s", "body": "b"])
        XCTAssertTrue(r.isError)
    }

    func testAutomationRefusalReadsAsAPermissionProblem() {
        let e = AppleScriptError(code: -1743, message: "Not authorized to send Apple events to Mail.")
        XCTAssertTrue(e.errorDescription!.contains("Automation"))
    }

    // MARK: Notes

    func testNotesListSortsByDateAndShowsFolders() async throws {
        let mock = MockScript()
        // First call: notes; second call: folders.
        mock.replies = [
            ["x-coredata://A/ICNote/p1", "Older", "2026-09-01T10:00:00", "Work"].joined(separator: fs) + rs
                + ["x-coredata://A/ICNote/p2", "Newer", "2026-09-19T10:00:00", "Ideas"].joined(separator: fs),
            ["Work", "12"].joined(separator: fs) + rs + ["Ideas", "3"].joined(separator: fs),
        ]
        let tool = NotesListTool(runner: mock)
        let r = try await tool.execute(parameters: [:])
        XCTAssertTrue(r.result.hasPrefix("Folders: Work (12), Ideas (3)"))
        XCTAssertLessThan(r.result.range(of: "Newer")!.lowerBound, r.result.range(of: "Older")!.lowerBound)
        XCTAssertTrue(r.result.contains("[p2]"), "short id shown")
        XCTAssertEqual(mock.scripts.count, 2)
    }

    func testNotesCreateBuildsHTMLWithParagraphsAndEscapes() {
        let s = AppleNotesScripts.create(title: "T <1>", body: "a & b\n\nc", folder: "Work")
        XCTAssertTrue(s.contains("<h1>T &lt;1></h1>"))
        XCTAssertTrue(s.contains("<div>a &amp; b</div><div><br></div><div>c</div>"))
        XCTAssertTrue(s.contains(#"at folder "Work""#))
    }

    // MARK: Calendar & Reminders

    func testCalendarEventsDefaultsToAWeekAndListsCalendarsOnRequest() async throws {
        let store = MockEvents()
        let soon = Date().addingTimeInterval(3_600)
        store.stored = [CalendarEvent(id: "1", title: "Standup", start: soon, end: soon.addingTimeInterval(1_800), allDay: false, calendar: "Work", location: nil, notes: nil),
                        CalendarEvent(id: "2", title: "Far", start: Date().addingTimeInterval(30 * 86_400), end: Date().addingTimeInterval(30 * 86_400 + 60), allDay: false, calendar: "Home", location: nil, notes: nil)]
        let r = try await CalendarEventsTool(store: store).execute(parameters: ["list_calendars": true])
        XCTAssertTrue(r.result.contains("Standup"))
        XCTAssertFalse(r.result.contains("Far"))
        XCTAssertTrue(r.result.contains("Calendars: Home, Work"))
    }

    func testCalendarCreateDefaultsToOneHourAndRejectsBadOrder() async throws {
        let store = MockEvents()
        let r = try await CalendarCreateEventTool(store: store).execute(parameters: ["title": "Review", "start": "2026-09-22T15:00:00+03:00"])
        XCTAssertFalse(r.isError)
        XCTAssertEqual(store.lastCreate!.2.timeIntervalSince(store.lastCreate!.1), 3_600)
        let bad = try await CalendarCreateEventTool(store: store).execute(parameters: ["title": "Review", "start": "2026-09-22T15:00:00+03:00", "end": "2026-09-22T14:00:00+03:00"])
        XCTAssertTrue(bad.isError)
    }

    func testDeniedAccessIsAnErrorThatNamesThePane() async throws {
        let store = MockEvents(); store.allow = false
        let r = try await CalendarEventsTool(store: store).execute(parameters: [:])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.result.contains("Calendars"))
    }

    func testRemindersListHidesCompletedByDefaultAndCompleteByPrefix() async throws {
        let store = MockEvents()
        store.items = [ReminderItem(id: "3F2A9C10-X", title: "Pay", due: nil, list: "Reminders", completed: false, notes: nil),
                       ReminderItem(id: "DONE", title: "Old", due: nil, list: "Reminders", completed: true, notes: nil)]
        let r = try await RemindersListTool(store: store).execute(parameters: [:])
        XCTAssertTrue(r.result.contains("Pay")); XCTAssertFalse(r.result.contains("Old"))
        let done = try await RemindersCompleteTool(store: store).execute(parameters: ["id": "3F2A9C10"])
        XCTAssertTrue(done.result.contains("☑ Pay"))
    }

    // MARK: Contacts

    func testContactsSearch() async throws {
        let r = try await ContactsSearchTool(store: MockContacts()).execute(parameters: ["query": "Sara"])
        XCTAssertTrue(r.result.contains("sara@example.com"))
        let none = try await ContactsSearchTool(store: MockContacts()).execute(parameters: ["query": "Zed"])
        XCTAssertTrue(none.result.contains("No contact"))
    }

    // MARK: Assembly

    func testFactoryRegistersOnlyTheAppsTurnedOn() {
        let all = makeAppleAppTools(.all, runner: MockScript(), events: MockEvents(), contacts: MockContacts())
        XCTAssertEqual(all.count, 15)
        let some = makeAppleAppTools([.calendar, .contacts], runner: MockScript(), events: MockEvents(), contacts: MockContacts())
        XCTAssertEqual(some.map(\.name).sorted(), ["calendar_create_event", "calendar_events", "contacts_search"])
        XCTAssertEqual(appleAppsPromptGuidance([]), "")
        XCTAssertTrue(appleAppsPromptGuidance(.mail).contains("mail_draft"))
        XCTAssertFalse(appleAppsPromptGuidance(.mail).contains("calendar_events"))
    }
}
#endif
