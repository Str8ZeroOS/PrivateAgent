import Testing
@testable import AgentCore

@Suite("Agent planner")
struct AgentPlannerTests {
    @Test("empty goals ask the user for a task")
    func emptyGoalAsksUser() async throws {
        let planner = RuleBasedAgentPlanner()
        let observation = AgentObservation(source: .privateAgentApp, userGoal: "   ")

        let plan = try await planner.makePlan(for: observation, allowedModes: [.inApp])

        #expect(plan.requiresUserApproval == false)
        #expect(plan.risk == .low)
        #expect(plan.steps.count == 1)

        guard case .askUser = plan.steps[0].action else {
            Issue.record("Expected askUser action")
            return
        }
    }

    @Test("normal in-app goals stay in app")
    func inAppGoalPlansAnswer() async throws {
        let planner = RuleBasedAgentPlanner()
        let observation = AgentObservation(source: .privateAgentApp, userGoal: "Summarize this conversation")

        let plan = try await planner.makePlan(for: observation, allowedModes: [.inApp, .appIntents, .shortcuts])

        #expect(plan.requiresUserApproval == false)
        #expect(plan.risk == .low)
        #expect(plan.summary == "Handle the request inside PrivateAgent.")

        guard case .answer(let text) = plan.steps[0].action else {
            Issue.record("Expected answer action")
            return
        }
        #expect(text == "Summarize this conversation")
    }

    @Test("external control goals choose Mac-assisted handoff first")
    func externalGoalChoosesMacAssistedHandoff() async throws {
        let planner = RuleBasedAgentPlanner()
        let observation = AgentObservation(source: .privateAgentApp, userGoal: "Open YouTube and tap the latest Tech Jarves video")

        let plan = try await planner.makePlan(for: observation, allowedModes: [.inApp, .shortcuts, .macAssisted])

        #expect(plan.requiresUserApproval == true)
        #expect(plan.risk == .medium)

        guard case .handoff(let handoff) = plan.steps[0].action else {
            Issue.record("Expected handoff action")
            return
        }
        #expect(handoff.target == .macAssisted)
    }
}
