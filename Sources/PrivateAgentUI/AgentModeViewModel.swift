import Foundation
import Observation
import AgentCore
import FlashMoEBridge

public enum AgentPlanningMode: String, CaseIterable, Identifiable, Sendable {
    case ruleBased
    case localModel

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ruleBased:
            return "Rules"
        case .localModel:
            return "Local Model"
        }
    }
}

@MainActor
@Observable
public final class AgentModeViewModel {
    public var goal: String = ""
    public var planningMode: AgentPlanningMode = .ruleBased
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

    public func makePlan(
        engine: PrivateAgentEngine? = nil,
        visibleText: [String] = [],
        controls: [AgentControl] = [],
        appContext: String? = nil
    ) async {
        errorMessage = nil
        executionResults = []

        let observation = AgentObservation(
            source: .privateAgentApp,
            userGoal: goal,
            visibleText: visibleText,
            controls: controls,
            appContext: appContext
        )

        do {
            switch planningMode {
            case .ruleBased:
                await session.updateAllowedModes(allowedModes)
                plan = try await session.plan(for: observation)
            case .localModel:
                guard let engine else {
                    throw PrivateAgentEngineTextGeneratorError.modelNotReady
                }
                let generator = PrivateAgentEngineTextGenerator(engine: engine)
                let planner = LLMAgentPlanner(generator: generator)
                plan = try await planner.makePlan(for: observation, allowedModes: allowedModes)
            }
        } catch {
            plan = nil
            errorMessage = error.localizedDescription
        }
    }

    public func runPlan() async {
        guard let plan else { return }
        errorMessage = nil
        executionResults = await runner.run(plan)
    }
}
