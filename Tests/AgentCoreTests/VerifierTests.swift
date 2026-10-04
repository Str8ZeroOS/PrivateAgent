import Testing
@testable import AgentCore

@Suite("Action and goal verifiers")
struct VerifierTests {
    @Test("separates ACTION_SUCCESS from ACTION_VERIFIED")
    func separatesSuccessFromVerified() {
        let verifier = ActionVerifier()
        let step = AgentStep(
            action: .openURL("https://example.com/video"),
            rationale: "Open the page",
            expectedResult: nil,
            verification: .none
        )
        let execution = ActionExecutionResult(action: step.action, status: .completed, message: "Opened URL.")
        let observation = AgentObservation(source: .privateAgentApp, userGoal: "Open example", visibleText: ["Home"])

        let success = verifier.verify(step: step, execution: execution, observation: observation)
        #expect(success.outcome == .actionSuccess)
        #expect(!success.verified)

        var verifyingStep = step
        verifyingStep.verification = .urlContains("example.com")
        let verifiedObservation = AgentObservation(
            source: .privateAgentApp,
            userGoal: "Open example",
            visibleText: ["https://example.com/video"]
        )
        let verified = verifier.verify(step: verifyingStep, execution: execution, observation: verifiedObservation)
        #expect(verified.outcome == .actionVerified)
        #expect(verified.verified)
    }

    @Test("marks unverified when observation does not match")
    func marksUnverified() {
        let verifier = ActionVerifier()
        let step = AgentStep(
            action: .tap(controlId: "play"),
            rationale: "Tap play",
            verification: .visibleTextContains("Playing")
        )
        let execution = ActionExecutionResult(action: step.action, status: .completed, message: "Tapped")
        let observation = AgentObservation(source: .macBridge, userGoal: "Play video", visibleText: ["Paused"])

        let result = verifier.verify(step: step, execution: execution, observation: observation)
        #expect(result.outcome == .actionUnverified)
        #expect(!result.verified)
    }

    @Test("goal verifier completes after an in-app answer")
    func goalCompletesAfterAnswer() {
        let step = AgentStep(action: .answer("Done"), rationale: "Answer locally")
        let record = StepRunRecord(
            step: step,
            execution: ActionExecutionResult(action: step.action, status: .completed, message: "Done"),
            outcome: .actionSuccess
        )
        let result = GoalVerifier().verify(
            goal: "Summarize this",
            observation: AgentObservation(source: .privateAgentApp, userGoal: "Summarize this"),
            history: [record]
        )
        #expect(result.isSatisfied)
    }
}
