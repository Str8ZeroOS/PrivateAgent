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

    @Test("goal verifier keeps going after a handoff once a Mac observation is live")
    func handoffContinuesOnMacObservation() {
        let step = AgentStep(
            action: .handoff(AgentHandoff(target: .macAssisted, reason: "Need the Mac bridge")),
            rationale: "External"
        )
        let record = StepRunRecord(
            step: step,
            execution: ActionExecutionResult(action: step.action, status: .completed, message: "Accepted"),
            outcome: .actionSuccess
        )
        let stillLocal = GoalVerifier().verify(
            goal: "Tap Instagram",
            observation: AgentObservation(source: .privateAgentApp, userGoal: "Tap Instagram"),
            history: [record]
        )
        #expect(!stillLocal.isSatisfied)

        let onMac = GoalVerifier().verify(
            goal: "Tap Instagram",
            observation: AgentObservation(
                source: .macBridge,
                userGoal: "Tap Instagram",
                controls: [AgentControl(id: "ax-0", label: "Instagram", role: .button)]
            ),
            history: [record]
        )
        #expect(!onMac.isSatisfied)
    }

    @Test("goal verifier completes a first-party deep link")
    func completesDeepLink() {
        let step = AgentStep(
            action: .openURL("privateagent://models"),
            rationale: "Deep link",
            verification: .appContextContains("models")
        )
        let record = StepRunRecord(
            step: step,
            execution: ActionExecutionResult(action: step.action, status: .completed, message: "Opened"),
            verification: StepVerificationResult(outcome: .actionVerified, verified: true, message: "ok"),
            outcome: .actionVerified
        )
        let result = GoalVerifier().verify(
            goal: "Open privateagent://models",
            observation: AgentObservation(
                source: .privateAgentApp,
                userGoal: "Open privateagent://models",
                appContext: "PrivateAgent.models"
            ),
            history: [record]
        )
        #expect(result.isSatisfied)
    }

    @Test("goal verifier does not finish a compound goal after the first verified tap")
    func compoundGoalStaysOpenAfterFirstTap() {
        let step = AgentStep(
            action: .tap(controlId: "nav.settings"),
            rationale: "Open settings",
            verification: .visibleTextContains("Settings")
        )
        let record = StepRunRecord(
            step: step,
            execution: ActionExecutionResult(action: step.action, status: .completed, message: "Activated Settings. screen=settings"),
            verification: StepVerificationResult(outcome: .actionVerified, verified: true, message: "Visible text contains Settings"),
            outcome: .actionVerified
        )
        let result = GoalVerifier().verify(
            goal: "Open Settings, then return to Agent Mode, then reply LOOP_OK",
            observation: AgentObservation(
                source: .privateAgentApp,
                userGoal: "Open Settings, then return to Agent Mode, then reply LOOP_OK",
                visibleText: ["Settings"],
                appContext: "PrivateAgent.settings"
            ),
            history: [record]
        )
        #expect(!result.isSatisfied)
        #expect(result.message.contains("1/3") || result.message.contains("Next:"))
    }

    @Test("echoed answer does not satisfy an Apple Notes goal")
    func notesEchoIsNotSuccess() {
        let step = AgentStep(action: .answer("Create a new note titled Agent Test"), rationale: "Echo")
        let record = StepRunRecord(
            step: step,
            execution: ActionExecutionResult(action: step.action, status: .completed, message: "Create a new note titled Agent Test"),
            outcome: .actionSuccess
        )
        let result = GoalVerifier().verify(
            goal: "Create a new note titled Agent Test with the body hello",
            observation: AgentObservation(
                source: .privateAgentApp,
                userGoal: "Create a new note titled Agent Test with the body hello"
            ),
            history: [record]
        )
        #expect(!result.isSatisfied)
    }
}
