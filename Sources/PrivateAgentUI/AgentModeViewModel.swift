import Foundation
import Observation
import AgentCore

@MainActor
@Observable
public final class AgentModeViewModel {
    public var goal: String = ""
    public private(set) var plan: AgentPlan?
    public private(set) var executionResults: [ActionExecutionResult] = []
    public private(set) var errorMessage: String?
    public var allowedModes: [AutomationMode] = [.inApp, .appIntents, .shortcuts]

    private let session: AgentSession
    private let runner: PlanRunner

    public init(
        session: AgentSession = AgentSession(),
        runner: PlanRunner = PlanRunner(executor: SystemActionExecutorFactory.makeDefaultExecutor())
    ) {
        self.session = session
        self.runner = runner
    }

    public func updateGoal(_ goal: String) {
        self.goal = goal
    }

    public func makePlan(visibleText: [String] = [], controls: [AgentControl] = [], appContext: String? = nil) async {
        errorMessage = nil
        executionResults = []
        await session.updateAllowedModes(allowedModes)

        let observation = AgentObservation(
            source: .privateAgentApp,
            userGoal: goal,
            visibleText: visibleText,
            controls: controls,
            appContext: appContext
        )

        do {
            plan = try await session.plan(for: observation)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func runPlan() async {
        guard let plan else { return }
        errorMessage = nil
        executionResults = await runner.run(plan)
    }
}
