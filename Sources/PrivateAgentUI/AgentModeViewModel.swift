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
    public var bridgeHost: String = UserDefaults.standard.string(forKey: "PrivateAgent.bridgeHost") ?? ""
    public var bridgePort: String = UserDefaults.standard.string(forKey: "PrivateAgent.bridgePort") ?? "8765"
    public var bridgeToken: String = UserDefaults.standard.string(forKey: "PrivateAgent.bridgeToken") ?? ""
    public private(set) var bridgeStatus: String?
    public private(set) var plan: AgentPlan?
    public private(set) var plannerDiagnostics: AgentPlannerDiagnostics?
    public private(set) var executionResults: [ActionExecutionResult] = []
    public private(set) var errorMessage: String?
    public private(set) var lastObservation: AgentObservation?
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

    public func saveBridgeSettings() {
        UserDefaults.standard.set(bridgeHost, forKey: "PrivateAgent.bridgeHost")
        UserDefaults.standard.set(bridgePort, forKey: "PrivateAgent.bridgePort")
        UserDefaults.standard.set(bridgeToken, forKey: "PrivateAgent.bridgeToken")
    }

    public func checkBridgeHealth() async {
        saveBridgeSettings()
        bridgeStatus = "Checking..."
        errorMessage = nil

        guard let client = makeBridgeClient() else {
            bridgeStatus = "Enter a valid host and port."
            return
        }

        do {
            let health = try await client.health()
            let mode = health.mode.map { " (\($0))" } ?? ""
            bridgeStatus = "Connected: \(health.status)\(mode)"
        } catch {
            bridgeStatus = "Connection failed: \(error.localizedDescription)"
        }
    }

    public func makePlan(
        engine: PrivateAgentEngine? = nil,
        visibleText: [String] = [],
        controls: [AgentControl] = [],
        appContext: String? = nil
    ) async {
        errorMessage = nil
        plannerDiagnostics = nil
        executionResults = []

        let observation = AgentObservation(
            source: .privateAgentApp,
            userGoal: goal,
            visibleText: visibleText,
            controls: controls,
            appContext: appContext
        )
        lastObservation = observation

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
                let result = try await planner.makePlanWithDiagnostics(for: observation, allowedModes: allowedModes)
                plan = result.plan
                plannerDiagnostics = result.diagnostics
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

    private func makeBridgeClient() -> LocalBridgeClient? {
        let trimmedHost = bridgeHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPort = bridgePort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, let port = Int(trimmedPort), port > 0 else { return nil }

        var components = URLComponents()
        components.scheme = "http"
        components.host = trimmedHost
        components.port = port
        guard let url = components.url else { return nil }

        return LocalBridgeClient(baseURL: url, token: bridgeToken)
    }
}
