import Testing
@testable import AgentCore

@Suite("Plan validator")
struct PlanValidatorTests {
    @Test("rejects empty plans and tap without external capability")
    func rejectsInvalidPlans() {
        let validator = PlanValidator()
        let observation = AgentObservation(source: .privateAgentApp, userGoal: "Tap Settings")
        let plan = AgentPlan(
            summary: "Tap a control",
            steps: [
                AgentStep(action: .tap(controlId: "settings"), rationale: "Open settings", risk: .high, requiresApproval: true)
            ],
            requiresUserApproval: true,
            risk: .high
        )

        let result = validator.validate(
            plan,
            observation: observation,
            allowedModes: [.inApp],
            executor: PlanningOnlyActionExecutor()
        )

        #expect(!result.isValid)
        #expect(result.requiresApproval)
        #expect(result.errorMessages.contains { $0.contains("Tap requires") })
    }

    @Test("accepts in-app answers and flags approval for high risk")
    func acceptsInAppAnswer() {
        let validator = PlanValidator()
        let observation = AgentObservation(source: .privateAgentApp, userGoal: "Summarize")
        let plan = AgentPlan(
            summary: "Answer in app",
            steps: [AgentStep(action: .answer("Summarize"), rationale: "Local answer")],
            risk: .low
        )

        let result = validator.validate(
            plan,
            observation: observation,
            allowedModes: [.inApp],
            executor: PlanningOnlyActionExecutor()
        )

        #expect(result.isValid)
        #expect(!result.requiresApproval)
    }

    @Test("rejects jailbreak handoff when the mode is not allowed")
    func rejectsDisallowedHandoff() {
        let validator = PlanValidator()
        let observation = AgentObservation(source: .privateAgentApp, userGoal: "Control Instagram")
        let plan = AgentPlan(
            summary: "Privileged handoff",
            steps: [
                AgentStep(
                    action: .handoff(AgentHandoff(target: .jailbreak, reason: "Need global control")),
                    rationale: "No App Store path"
                )
            ]
        )

        let result = validator.validate(
            plan,
            observation: observation,
            allowedModes: [.inApp],
            executor: PlanningOnlyActionExecutor()
        )

        #expect(!result.isValid)
        #expect(result.errorMessages.contains { $0.contains("not allowed") || $0.contains("Jailbreak") })
    }

    @Test("policy auto-approves in-app answers and denies jailbreak")
    func policyDecisions() {
        let policy = AgentPolicy.default
        let answerPlan = AgentPlan(
            summary: "Answer",
            steps: [AgentStep(action: .answer("Hi"), rationale: "Local")],
            risk: .low
        )
        let validation = PlanValidationResult(isValid: true, issues: [], requiresApproval: false)
        #expect(policy.decision(for: answerPlan, validation: validation) == .allow)

        let jailbreakPlan = AgentPlan(
            summary: "Privileged",
            steps: [
                AgentStep(
                    action: .handoff(AgentHandoff(target: .jailbreak, reason: "Need control")),
                    rationale: "No App Store path",
                    risk: .high,
                    requiresApproval: true
                )
            ],
            requiresUserApproval: true,
            risk: .high
        )
        guard case .deny = policy.decision(for: jailbreakPlan, validation: validation) else {
            Issue.record("Expected jailbreak deny")
            return
        }
    }

    @Test("first-party privateagent URLs are valid without extra approval")
    func acceptsPrivateAgentDeepLink() {
        let observation = InAppWorkspace.observation(goal: "Open models")
        let plan = AgentPlan(
            summary: "Open models",
            steps: [AgentStep(action: .openURL("privateagent://models"), rationale: "First-party deep link")]
        )
        let result = PlanValidator().validate(
            plan,
            observation: observation,
            allowedModes: [.inApp],
            executor: InAppActionExecutor()
        )
        #expect(result.isValid)
        #expect(!result.requiresApproval)
    }
}
