import Testing
@testable import AgentCore

@Suite("Goal breakdown")
struct GoalBreakdownTests {
    @Test("splits then / and then / after that clauses")
    func splitsSequentialClauses() {
        let progress = GoalBreakdown.parse("Open Settings, then return to Agent Mode, then reply LOOP_OK")
        #expect(progress.subGoals.count == 3)
        #expect(progress.subGoals[0].kind == .navigateInApp)
        #expect(progress.subGoals[0].screen == .settings)
        #expect(progress.subGoals[1].kind == .returnToScreen)
        #expect(progress.subGoals[1].screen == .agentMode)
        #expect(progress.subGoals[2].kind == .reply)
        #expect(progress.subGoals[2].replyText == "LOOP_OK")
    }

    @Test("classifies Apple Notes as an undriveable external app")
    func classifiesNotesAsExternal() {
        let progress = GoalBreakdown.parse("Create a new note titled Agent Test with the body hello from Str8ZeRO")
        #expect(progress.subGoals.count == 1)
        #expect(progress.subGoals[0].kind == .externalApp)
        #expect(GoalBreakdown.isUndriveableExternalApp(progress.subGoals[0].text))
    }

    @Test("firstClause returns the next unfinished piece")
    func firstClauseIsTheLeadingSubGoal() {
        #expect(GoalBreakdown.firstClause(of: "Open Settings, then reply LOOP_OK") == "Open Settings")
        #expect(GoalBreakdown.parseReply("reply LOOP_OK") == "LOOP_OK")
        #expect(GoalBreakdown.parseReply("say \"done\"") == "done")
    }
}
