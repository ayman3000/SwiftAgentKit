import Testing
import Foundation
@testable import SwiftAgentKit

/// The memory files' formats as pure text rules. Every writer goes through
/// these, so a duplicate key, a lost section or a doubled heading cannot
/// happen whoever writes.
struct MemoryDocumentsTests {

    // MARK: USER.md

    @Test func settingAnExistingKeyReplacesItsLineAndKeepsItsSpelling() {
        let doc = "# User\n\n- **Name:** Ayman\n- **Role:** Developer\n"
        let out = MemoryDocuments.settingUserKey("name", value: "Ayman H", in: doc)
        let keys = MemoryDocuments.userKeys(out)
        #expect(keys.map { $0.key } == ["Name", "Role"])
        #expect(keys.map { $0.value } == ["Ayman H", "Developer"])
    }

    @Test func duplicateKeysCollapseToOneLine() {
        let doc = "# User\n\n- **Plan:** a\n- **Name:** Ayman\n- **Plan:** b\n- **plan:** c\n"
        let out = MemoryDocuments.settingUserKey("Plan", value: "Keep plan.md current", in: doc)
        let plans = MemoryDocuments.userKeys(out).filter { $0.key.lowercased() == "plan" }
        #expect(plans.count == 1)
        #expect(plans.first?.value == "Keep plan.md current")
        #expect(MemoryDocuments.userValue("Name", in: out) == "Ayman")
    }

    @Test func aNewKeyIsAppended() {
        let doc = "# User\n\n- **Name:** A\n"
        #expect(MemoryDocuments.settingUserKey("Role", value: "B", in: doc)
                == "# User\n\n- **Name:** A\n- **Role:** B\n")
    }

    @Test func anEmptyDocumentGetsAHeading() {
        #expect(MemoryDocuments.settingUserKey("Name", value: "A", in: "") == "# User\n\n- **Name:** A\n")
    }

    @Test func valuesStayOnOneLine() {
        let out = MemoryDocuments.settingUserKey("Answers", value: "Short\nend with next step", in: "# User\n")
        #expect(MemoryDocuments.userValue("Answers", in: out) == "Short end with next step")
    }

    @Test func removingAKeyDropsEveryCopy() {
        let doc = "# User\n\n- **Plan:** a\n- **Name:** Ayman\n- **plan:** b\n"
        let out = MemoryDocuments.removingUserKey("PLAN", in: doc)
        #expect(MemoryDocuments.userKeys(out).map { $0.key } == ["Name"])
    }

    // MARK: AGENT.md

    @Test func theDefaultIsStructuredAndTheOldSoulIsNot() {
        #expect(MemoryDocuments.isStructuredAgentProfile(MemoryDocuments.defaultAgentProfile))
        #expect(!MemoryDocuments.isStructuredAgentProfile(MemoryDocuments.legacyKitDefaultAgentProfile))
        #expect(!MemoryDocuments.isStructuredAgentProfile("# Paywall copy and ambiguous widget finders\n\nA lesson."))
    }

    @Test func anIdentityChangeKeepsTheOtherSections() {
        let doc = MemoryDocuments.defaultAgentProfile
        let out = MemoryDocuments.editingAgentProfile(doc, section: .identity, change: "Name: Nemo")
        #expect(MemoryDocuments.agentSection(.identity, in: out) == "Name: Nemo")
        for section in [AgentProfileSection.mission, .tone, .principles] {
            #expect(MemoryDocuments.agentSection(section, in: out) == MemoryDocuments.agentSection(section, in: doc))
        }
        #expect(MemoryDocuments.isStructuredAgentProfile(out))
    }

    @Test func identityLinesMergeByLabel() {
        let doc = MemoryDocuments.replacingAgentSection(.identity, with: "Name: Naseem\nAddress the user: Ayman",
                                                        in: MemoryDocuments.defaultAgentProfile)
        let out = MemoryDocuments.editingAgentProfile(doc, section: .identity, change: "name: Nemo")
        #expect(MemoryDocuments.agentSection(.identity, in: out) == "name: Nemo\nAddress the user: Ayman")
    }

    @Test func toneIsReplaced() {
        let out = MemoryDocuments.editingAgentProfile(MemoryDocuments.defaultAgentProfile,
                                                      section: .tone, change: "Formal and brief.")
        #expect(MemoryDocuments.agentSection(.tone, in: out) == "Formal and brief.")
    }

    @Test func aPrincipleIsAddedOnce() {
        var doc = MemoryDocuments.defaultAgentProfile
        doc = MemoryDocuments.editingAgentProfile(doc, section: .principles, change: "Ask before deleting files")
        doc = MemoryDocuments.editingAgentProfile(doc, section: .principles, change: "- Ask before deleting files")
        #expect(MemoryDocuments.agentSection(.principles, in: doc) == "- Ask before deleting files")
    }

    @Test func aMissingSectionIsAddedAndOldTextKept() {
        let old = "# Paywall copy\n\nA lesson about widget finders."
        let out = MemoryDocuments.editingAgentProfile(old, section: .tone, change: "Warm")
        #expect(out.contains("A lesson about widget finders."))
        #expect(MemoryDocuments.agentSection(.tone, in: out) == "Warm")
    }

    // MARK: Facts

    @Test func aFactHasExactlyOneHeading() {
        #expect(MemoryDocuments.factMarkdown(title: "T", body: "# T\n\n# T\n\nbody") == "# T\n\nbody\n")
        #expect(MemoryDocuments.factBody("# T\n\n# t\n\nbody\nmore\n", title: "T") == "body\nmore")
    }

    @Test func aBodyThatStartsWithAnotherHeadingIsKept() {
        #expect(MemoryDocuments.factBody("# T\n\n# Other\nx", title: "T") == "# Other\nx")
    }

    // MARK: Fix round 1 — hand-edited USER.md keys

    @Test func aBoldKeyWithTheColonOutsideIsTheSameKey() {
        let doc = "# User\n\n- **Name**: Ayman\n"
        #expect(MemoryDocuments.userValue("Name", in: doc) == "Ayman")
        let out = MemoryDocuments.settingUserKey("name", value: "Ayman H", in: doc)
        #expect(MemoryDocuments.userKeys(out).map { $0.key } == ["Name"])
        #expect(MemoryDocuments.userValue("Name", in: out) == "Ayman H")
    }

    @Test func aPlainKeyLineIsTheSameKey() {
        let doc = "# User\n\n- Name: Ayman\n- **Role:** Developer\n"
        let out = MemoryDocuments.settingUserKey("Name", value: "Ayman H", in: doc)
        #expect(MemoryDocuments.userKeys(out).map { $0.key } == ["Name", "Role"])
        #expect(MemoryDocuments.userValue("Name", in: out) == "Ayman H")
    }

    @Test func linesThatAreNotKeyLinesStayUntouched() {
        let long = "- This is a long sentence that happens to contain a colon much later: here"
        let doc = "# User\n\nWhat the agent knows about you.\n- Prefers short answers\n- See https://example.com\n\(long)\n- **Name:** A\n"
        #expect(MemoryDocuments.userKeys(doc).map { $0.key } == ["Name"])
        let out = MemoryDocuments.settingUserKey("Name", value: "B", in: doc)
        #expect(out == doc.replacingOccurrences(of: "- **Name:** A", with: "- **Name:** B"))
    }

    @Test func removingAKeyTrimsItLikeSettingDoes() {
        let doc = "# User\n\n- **Name:** Ayman\n- **Role:** Dev\n"
        let out = MemoryDocuments.removingUserKey("  Name \n", in: doc)
        #expect(MemoryDocuments.userKeys(out).map { $0.key } == ["Role"])
    }
}
