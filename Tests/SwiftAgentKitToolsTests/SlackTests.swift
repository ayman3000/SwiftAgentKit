import Testing
import Foundation
@testable import SwiftAgentKitTools
import SwiftAgentKit

struct SlackWireTests {

    // MARK: Requests

    @Test func readsAreSignedAndTheTokenNeverLandsInTheURL() throws {
        let get = SlackAPI.get("conversations.history", token: "xoxp-secret",
                               query: ["channel": "C1", "limit": "50"])
        #expect(get.url?.path == "/api/conversations.history")
        #expect(get.url?.query == "channel=C1&limit=50", "query is ordered, so the test is stable")
        #expect(get.value(forHTTPHeaderField: "Authorization") == "Bearer xoxp-secret")
        #expect(get.url?.absoluteString.contains("xoxp-secret") == false)
    }

    @Test func postingSendsJSON() throws {
        let post = SlackAPI.post("chat.postMessage", token: "t", body: ["channel": "C1", "text": "hello"])
        #expect(post.httpMethod == "POST")
        #expect(post.value(forHTTPHeaderField: "Content-Type")?.contains("application/json") == true)
        let body = try #require(post.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["text"] as? String == "hello")
    }

    // MARK: Responses

    /// Slack reports failure with 200 and ok:false, so the body is the truth.
    @Test func aFailureInTheBodyIsAnError() throws {
        let ok = try SlackAPI.payload(Data(#"{"ok":true,"channels":[]}"#.utf8))
        #expect(ok["ok"] as? Bool == true)
        #expect(throws: SlackAPI.SlackError.self) {
            try SlackAPI.payload(Data(#"{"ok":false,"error":"channel_not_found"}"#.utf8))
        }
    }

    @Test func errorCodesBecomeSentencesThatSayWhatToDo() {
        #expect(SlackAPI.sentence(for: "invalid_auth").contains("xoxp-"))
        let scoped = SlackAPI.sentence(for: "missing_scope", needed: "channels:history")
        #expect(scoped.contains("channels:history"))
        #expect(scoped.contains("User Token Scopes"))
        #expect(SlackAPI.sentence(for: "not_in_channel").contains("Join the channel"))
        #expect(SlackAPI.sentence(for: "channel_not_found").contains("slack_channels"))
        #expect(SlackAPI.sentence(for: "wat").contains("wat"))
    }

    @Test func missingScopeIsReadFromEitherShapeSlackUses() throws {
        // Slack puts the needed scope in `needed`, or in response_metadata.
        do {
            _ = try SlackAPI.payload(Data(#"{"ok":false,"error":"missing_scope","needed":"search:read"}"#.utf8))
            Issue.record("expected a throw")
        } catch let error as SlackAPI.SlackError {
            #expect(error.errorDescription?.contains("search:read") == true)
        }
        do {
            _ = try SlackAPI.payload(Data(#"{"ok":false,"error":"missing_scope","response_metadata":{"scopes":["im:history"]}}"#.utf8))
            Issue.record("expected a throw")
        } catch let error as SlackAPI.SlackError {
            #expect(error.errorDescription?.contains("im:history") == true)
        }
    }

    // MARK: Values

    @Test func timestampsAreEpochSecondsWithMicroseconds() {
        let date = try! #require(SlackAPI.date(fromTS: "1789693845.123456"))
        #expect(abs(date.timeIntervalSince1970 - 1789693845) < 1)
        #expect(SlackAPI.date(fromTS: "nonsense") == nil)
    }

    /// Slack's own markup is unreadable as prose.
    @Test func mentionsLinksAndChannelsAreMadeReadable() {
        let names = ["U123": "sara", "U999": "omar"]
        #expect(SlackAPI.readable("hi <@U123> and <@U999>", users: names) == "hi @sara and @omar")
        #expect(SlackAPI.readable("see <#C42|release>") == "see #release")
        #expect(SlackAPI.readable("<https://x.com|the page>") == "the page (https://x.com)")
        #expect(SlackAPI.readable("<https://x.com>") == "https://x.com")
        #expect(SlackAPI.readable("a &amp; b") == "a & b")
        // An unknown id still reads as a mention rather than raw markup.
        #expect(SlackAPI.readable("ping <@U777>") == "ping @U777")
    }

    @Test func channelNamesAndIdsAreBothAccepted() {
        #expect(SlackAPI.normalizedChannelName("#release") == "release")
        #expect(SlackAPI.normalizedChannelName("release") == "release")
        #expect(SlackAPI.looksLikeChannelID("C01ABCDEF23"))
        #expect(SlackAPI.looksLikeChannelID("D01ABCDEF23"))
        #expect(!SlackAPI.looksLikeChannelID("release"))
        #expect(!SlackAPI.looksLikeChannelID("#release"))
    }

    // MARK: Shapes

    @Test func channelsCarryWhetherYouCanActuallyReadThem() throws {
        let json = """
        {"ok":true,"channels":[
          {"id":"C1","name":"release","is_private":false,"is_member":true,"topic":{"value":"ship it"}},
          {"id":"C2","name":"secret","is_private":true,"is_member":false}]}
        """
        let list = SlackAPI.channels(in: try SlackAPI.payload(Data(json.utf8)))
        #expect(list.map(\.id) == ["C1", "C2"])
        #expect(list[0].line == "#release — ship it")
        #expect(list[1].line.contains("private"))
        #expect(list[1].line.contains("not joined"))
    }

    @Test func messagesReadOldestFirstAndPointAtTheirThreads() throws {
        let json = """
        {"ok":true,"messages":[
          {"ts":"1789693900.000200","user":"U999","text":"second"},
          {"ts":"1789693845.000100","user":"U123","text":"first","reply_count":2,"thread_ts":"1789693845.000100"}]}
        """
        let messages = SlackAPI.messages(in: try SlackAPI.payload(Data(json.utf8)))
        #expect(messages.map(\.text) == ["first", "second"], "oldest first, the way a person reads")
        let line = messages[0].line(users: ["U123": "sara"])
        #expect(line.contains("@sara: first"))
        #expect(line.contains("2 replies"))
        #expect(line.contains("1789693845.000100"))
    }

    @Test func searchHitsNameTheirChannel() throws {
        let json = """
        {"ok":true,"messages":{"matches":[
          {"ts":"1789693845.1","user":"U123","text":"deploy failed","channel":{"id":"C1","name":"incidents"}}]}}
        """
        let hits = SlackAPI.hits(in: try SlackAPI.payload(Data(json.utf8)))
        #expect(hits.count == 1)
        #expect(hits[0].line(users: ["U123": "sara"]).hasPrefix("#incidents ["))
        #expect(hits[0].line(users: [:]).contains("@U123"))
    }

    @Test func displayNamesFallBackSensibly() throws {
        let json = """
        {"ok":true,"members":[
          {"id":"U1","name":"login","profile":{"display_name":"Sara","real_name":"Sara Ali"}},
          {"id":"U2","name":"login2","profile":{"display_name":"","real_name":"Omar Said"}},
          {"id":"U3","name":"login3","profile":{}}]}
        """
        let names = SlackAPI.users(in: try SlackAPI.payload(Data(json.utf8)))
        #expect(names["U1"] == "Sara")
        #expect(names["U2"] == "Omar Said", "an empty display name falls back to the real one")
        #expect(names["U3"] == "login3")
    }

    // MARK: The tools themselves

    @Test func postingAsksEveryTimeAndReadingNeverDoes() {
        let slack = SlackSession(token: { "t" })
        #expect(SlackPostTool(slack: slack).requiresConfirmation)
        #expect(SlackPostTool(slack: slack).requiresConfirmationEvenWhenAutonomous)
        #expect(SlackChannelsTool(slack: slack).isReadOnly)
        #expect(SlackHistoryTool(slack: slack).isReadOnly)
        #expect(SlackSearchTool(slack: slack).isReadOnly)
        #expect(SlackThreadTool(slack: slack).isReadOnly)
    }

    @Test func noTokenIsSaidPlainlyRatherThanFailingOpaquely() async throws {
        let tools = makeSlackTools(token: { nil })
        #expect(tools.count == 5)
        let channels = try #require(tools.first { $0.name == "slack_channels" })
        let result = try await channels.execute(parameters: [:])
        #expect(result.isError)
        #expect(result.result.contains("xoxp-"))
    }

    @Test func requiredArgumentsAreCheckedBeforeAnyCall() async throws {
        let slack = SlackSession(token: { "t" })
        #expect(try await SlackHistoryTool(slack: slack).execute(parameters: [:]).isError)
        #expect(try await SlackThreadTool(slack: slack).execute(parameters: ["channel": "x"]).isError)
        #expect(try await SlackSearchTool(slack: slack).execute(parameters: ["query": "  "]).isError)
        #expect(try await SlackPostTool(slack: slack).execute(parameters: ["channel": "x", "text": " "]).isError)
    }

    @Test func guidanceTellsTheModelToShowAMessageBeforePosting() {
        let g = slackPromptGuidance()
        #expect(g.contains("slack_post"))
        #expect(g.contains("cannot be taken back"))
        #expect(g.contains("Never post to a channel the user did not name"))
    }
}
