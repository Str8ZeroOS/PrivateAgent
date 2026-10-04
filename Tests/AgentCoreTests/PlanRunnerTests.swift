import Testing
@testable import AgentCore

@Suite("Plan runner")
struct PlanRunnerTests {
    @Test("runs planning-only actions")
    func runsPlanningOnlyActions() async {
        let plan = AgentPlan(
            summary: "Answer in app.",
            steps: [
                AgentStep(action: .answer("Done"), rationale: "Simple in-app response."),
                AgentStep(action: .askUser("Anything else?"), rationale: "Continue the conversation.")
            ]
        )
        let runner = PlanRunner(executor: PlanningOnlyActionExecutor())

        let results = await runner.run(plan)

        #expect(results.count == 2)
        #expect(results[0].status == .completed)
        #expect(results[0].message == "Done")
        #expect(results[1].status == .completed)
    }

    @Test("router skips unsupported actions when no executor is registered")
    func routerSkipsUnsupportedAction() async throws {
        let router = ActionExecutorRouter(executors: [PlanningOnlyActionExecutor()])
        let result = try await router.execute(.tap(controlId: "settings"))

        #expect(result.status == .skipped)
    }
}
