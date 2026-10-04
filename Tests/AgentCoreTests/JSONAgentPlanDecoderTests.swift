import Testing
@testable import AgentCore

@Suite("JSON agent plan decoder")
struct JSONAgentPlanDecoderTests {
    @Test("decodes JSON plan embedded in model prose")
    func decodesEmbeddedJSONPlan() throws {
        let json = """
        Here is the plan:
        {
          "summary": "Open a safe URL.",
          "steps": [
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "action": { "openURL": { "_0": "https://example.com" } },
              "rationale": "The user requested a web handoff.",
              "status": "pending"
            }
          ],
          "requiresUserApproval": true,
          "risk": "medium"
        }
        """

        let plan = try JSONAgentPlanDecoder().decodePlan(from: json)

        #expect(plan.summary == "Open a safe URL.")
        #expect(plan.requiresUserApproval == true)
        #expect(plan.risk == .medium)
        #expect(plan.steps.count == 1)

        guard case .openURL(let url) = plan.steps[0].action else {
            Issue.record("Expected openURL action")
            return
        }
        #expect(url == "https://example.com")
    }
}
