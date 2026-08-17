//
//  SkillTriggerQualityTests.swift
//  SwiftAgentKit
//
//  Trigger-quality hardening: model-authored trigger lists routinely contain
//  generic English words ("current", "work", "needs"), and the old raw
//  substring match made every ordinary query light up unrelated skills.
//  New contract: phrases match as substrings; single words must be
//  non-stopwords and match a whole query word (prefix allowed for plurals
//  and gerunds).
//

import Foundation
import Testing
@testable import SwiftAgentKit

@Test func genericStopwordTriggersDoNotFire() {
    // The real-world case: dev-workflow skills imported with prose-derived
    // trigger lists were activated by "current" in a time question.
    let subagentSkill = AgentSkill(
        name: "subagent-driven-development",
        triggerKeywords: ["subagent", "driven", "development", "executing", "implementation",
                          "plans", "independent", "tasks", "current", "session"],
        instructions: "…"
    )
    let worktreesSkill = AgentSkill(
        name: "using-git-worktrees",
        triggerKeywords: ["git", "worktrees", "starting", "feature", "work", "needs",
                          "isolation", "current", "workspace", "executing", "implementation", "plans"],
        instructions: "…"
    )

    let query = "What time is it right now? Use your current time tool."
    #expect(subagentSkill.matches(query) == false)
    #expect(worktreesSkill.matches(query) == false)
}

@Test func distinctiveSingleWordStillFiresAlone() {
    let skill = AgentSkill(name: "chart", triggerKeywords: ["chart", "graph", "plot"], instructions: "…")
    #expect(skill.matches("Create a bar chart of sales") == true)
    #expect(skill.matches("Read this file") == false)
}

@Test func singleWordMatchesWholeWordsAndPrefixesOnly() {
    let scaffold = AgentSkill(name: "scaffold", triggerKeywords: ["scaffold"], instructions: "…")
    #expect(scaffold.matches("scaffolding a new app") == true)      // prefix covers gerund
    #expect(scaffold.matches("please scaffold it") == true)         // whole word

    // Raw substring accidents must be gone: "art" inside "start".
    let art = AgentSkill(name: "art", triggerKeywords: ["art"], instructions: "…")
    #expect(art.matches("start the timer") == false)
    #expect(art.matches("generate some art for me") == true)
}

@Test func phraseTriggersStillMatchAsSubstrings() {
    let skill = AgentSkill(name: "scaffold", triggerKeywords: ["new project"], instructions: "…")
    #expect(skill.matches("Set up a new project for me") == true)
    #expect(skill.matches("open the project") == false)
}

@Test func realDomainTriggersStillReachTheirSkills() {
    // The same imported skills must still fire for the queries they are FOR.
    let worktreesSkill = AgentSkill(
        name: "using-git-worktrees",
        triggerKeywords: ["git", "worktrees", "starting", "feature", "work", "needs",
                          "isolation", "current", "workspace", "executing", "implementation", "plans"],
        instructions: "…"
    )
    #expect(worktreesSkill.matches("set up git worktrees for this feature") == true)
    #expect(worktreesSkill.matches("what is the isolation model here?") == true)
}
