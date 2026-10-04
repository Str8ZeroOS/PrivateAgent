import Testing
@testable import AgentCore

@Suite("LLM agent planner")
struct LLMAgentPlannerTests {
    @Test("repairs malformed JSON plan once")
    func repairsMalformedJSONPlan() async throws {
        let generator = RepairingGenerator(responses: [
            "This is not valid plan JSON.",
            """
            {
              "summary": "Ask for clarification.",
              "steps": [
                {
                  "id": "00000000-0000-0000-0000-000000000002",
                  "action": { "askUser": { "_0": "Which app should I use?" } },
                  "rationale": "The task needs a target app.",
                  "status": "pending"
                }
              ],
              "requiresUserApproval": false,
              "risk": "low"
            }
            """
        ])
        let planner = LLMAgentPlanner(generator: generator, maxRepairAttempts: 1)
        let observation = AgentObservation(source: .privateAgentApp, userGoal: "Do something")

        let plan = try await planner.makePlan(for: observation, allowedModes: [.inApp])

        #expect(plan.summary == "Ask for clarification.")
        #expect(plan.steps.count == 1)
        guard case .askUser(let question) = plan.steps[0].action else {
            Issue.record("Expected askUser action")
            return
        }
        #expect(question == "Which app should I use?")
    }
}

private actor ResponseStore {
    private var responses: [String]

    init(responses: [String]) {
        self.responses = responses
    }

    func next() -> String {
        if responses.isEmpty { return "{}" }
        return responses.removeFirst()
    }
}

private struct RepairingGenerator: AgentTextGenerating {
    private let store: ResponseStore

    init(responses: [String]) {
        self.store = ResponseStore(responses: responses)
    }

    @MainActor
    func generateText(prompt: String) async throws -> String {
        await store.next()
    }
}
