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
    public var wdaHost: String = UserDefaults.standard.string(forKey: "PrivateAgent.wdaHost") ?? "127.0.0.1"
    public var wdaPort: String = UserDefaults.standard.string(forKey: "PrivateAgent.wdaPort") ?? "8101"
    public var wdaToken: String = UserDefaults.standard.string(forKey: "PrivateAgent.wdaToken") ?? ""
    public private(set) var bridgeStatus: String?
    public private(set) var wdaStatus: String?
    public private(set) var plan: AgentPlan?
    public private(set) var plannerDiagnostics: AgentPlannerDiagnostics?
    public private(set) var executionResults: [ActionExecutionResult] = []
    public private(set) var errorMessage: String?
    public private(set) var lastObservation: AgentObservation?
    public private(set) var phase: AgentPhase = .idle
    public private(set) var isRunning = false
    public private(set) var stepRecords: [StepRunRecord] = []
    public private(set) var loopSnapshot: AgentLoopSnapshot?
    public private(set) var pendingApproval: AgentApprovalRequest?
    public var allowedModes: [AutomationMode] = [.inApp, .appIntents, .shortcuts]

    private let session: AgentSession
    private let runner: PlanRunner
    private var approvalBroker: AgentApprovalBroker?
    private var runningLoop: AgentLoop?

    public init(
        session: AgentSession = AgentSession(),
        runner: PlanRunner = PlanRunner(executor: SystemActionExecutorFactory.makeDefaultExecutor())
    ) {
        self.session = session
        self.runner = runner
        reloadPairing()
    }

    public func reloadPairing() {
        guard let pairing = BridgePairingStore.load() else { return }
        apply(pairing)
    }

    public func apply(_ pairing: BridgePairing) {
        bridgeHost = pairing.host
        bridgePort = String(pairing.port)
        bridgeToken = pairing.token
        wdaHost = pairing.wdaHost
        wdaPort = String(pairing.wdaPort)
        wdaToken = pairing.wdaToken
        allowedModes = pairing.recommendedModes(startingFrom: allowedModes)
        saveBridgeSettings()
        BridgePairingStore.save(pairing)
        let diagnosis = BridgePairingDoctor.diagnose(
            pairing: pairing,
            onDarwin: {
                #if os(macOS)
                return true
                #else
                return false
                #endif
            }()
        )
        bridgeStatus = "Paired \(pairing.host):\(pairing.port). \(diagnosis.nextAction)"
    }

    public func updateGoal(_ goal: String) {
        self.goal = goal
    }

    public func saveBridgeSettings() {
        UserDefaults.standard.set(bridgeHost, forKey: "PrivateAgent.bridgeHost")
        UserDefaults.standard.set(bridgePort, forKey: "PrivateAgent.bridgePort")
        UserDefaults.standard.set(bridgeToken, forKey: "PrivateAgent.bridgeToken")
        UserDefaults.standard.set(wdaHost, forKey: "PrivateAgent.wdaHost")
        UserDefaults.standard.set(wdaPort, forKey: "PrivateAgent.wdaPort")
        UserDefaults.standard.set(wdaToken, forKey: "PrivateAgent.wdaToken")
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

    public func checkWDAStatus() async {
        saveBridgeSettings()
        wdaStatus = "Checking..."
        errorMessage = nil

        guard let client = makeWDAClient() else {
            wdaStatus = "Enter a valid WebDriverAgent host and port."
            return
        }

        do {
            let status = try await client.status()
            let session = status.sessionId.map { " session=\($0)" } ?? ""
            wdaStatus = status.ready
                ? "Ready: \(status.message)\(session)"
                : "Not ready: \(status.message)"
        } catch {
            wdaStatus = "Connection failed: \(error.localizedDescription)"
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

        var observation = await InAppWorkspaceStore.shared.snapshot(goal: goal)
        if !visibleText.isEmpty { observation.visibleText = visibleText }
        if !controls.isEmpty { observation.controls = controls }
        if let appContext { observation.appContext = appContext }
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

    public func runAgent(
        engine: PrivateAgentEngine? = nil,
        visibleText: [String] = [],
        controls: [AgentControl] = [],
        appContext: String? = nil
    ) async {
        errorMessage = nil
        plannerDiagnostics = nil
        executionResults = []
        stepRecords = []
        pendingApproval = nil
        isRunning = true
        phase = .understanding

        let broker = AgentApprovalBroker()
        approvalBroker = broker

        let planner: any AgentPlanning
        switch planningMode {
        case .ruleBased:
            planner = RuleBasedAgentPlanner()
        case .localModel:
            guard let engine else {
                errorMessage = PrivateAgentEngineTextGeneratorError.modelNotReady.localizedDescription
                isRunning = false
                phase = .failed
                return
            }
            planner = LLMAgentPlanner(
                generator: PrivateAgentEngineTextGenerator(engine: engine),
                maxRepairAttempts: AgentLoopLimits.default.maxJSONRepairAttempts
            )
        }

        let eventBridge = AgentLoopEventBridge { [weak self] event in
            self?.apply(event)
        }

        saveBridgeSettings()
        let runtime = CapabilityRuntime.make(
            allowedModes: allowedModes,
            navigator: AppRouterNavigator(),
            workspace: .shared,
            macClient: allowedModes.contains(.macAssisted) ? makeBridgeClient() : nil,
            wdaClient: allowedModes.contains(.webDriverAgent) ? makeWDAClient() : nil,
            extraExecutors: SystemActionExecutorFactory.platformExecutors()
        )

        let loop = AgentLoop(
            configuration: AgentLoopConfiguration(
                observer: runtime.observer,
                planner: planner,
                executor: runtime.executor,
                approval: broker,
                allowedModes: allowedModes,
                eventHandler: { event in
                    await eventBridge.emit(event)
                }
            )
        )
        runningLoop = loop

        let snapshot = await loop.run(goal: goal)
        apply(snapshot: snapshot)
        isRunning = false
        runningLoop = nil
        approvalBroker = nil
    }

    public func cancelAgent() async {
        await runningLoop?.cancel()
        await approvalBroker?.respond(.cancelled)
    }

    public func approvePendingPlan() async {
        await approvalBroker?.respond(.approved)
    }

    public func rejectPendingPlan() async {
        await approvalBroker?.respond(.rejected)
    }

    public func apply(_ event: AgentLoopEvent) {
        switch event {
        case .phaseChanged(let newPhase):
            phase = newPhase
        case .observation(let observation):
            lastObservation = observation
        case .planUpdated(let newPlan):
            plan = newPlan
        case .validation(let validation):
            if !validation.isValid {
                errorMessage = validation.errorMessages.joined(separator: "\n")
            }
        case .awaitingApproval(let request):
            pendingApproval = request
            plan = request.plan
            phase = .awaitingApproval
        case .stepStarted:
            break
        case .actionResult(let result):
            executionResults.append(result)
        case .verification:
            break
        case .recovery(let decision):
            if case .stop(let message) = decision.strategy {
                errorMessage = message
            }
        }
    }

    private func apply(snapshot: AgentLoopSnapshot) {
        loopSnapshot = snapshot
        phase = snapshot.phase
        plan = snapshot.plan
        lastObservation = snapshot.observation
        stepRecords = snapshot.stepRecords
        plannerDiagnostics = snapshot.plannerDiagnostics
        pendingApproval = snapshot.pendingApproval
        if let message = snapshot.outcomeMessage, snapshot.phase == .failed || snapshot.phase == .blocked {
            errorMessage = message
        }
        executionResults = snapshot.stepRecords.map(\.execution)
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

    private func makeWDAClient() -> LocalWebDriverAgentClient? {
        let trimmedHost = wdaHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPort = wdaPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, let port = Int(trimmedPort), port > 0 else { return nil }

        var components = URLComponents()
        components.scheme = "http"
        components.host = trimmedHost
        components.port = port
        guard let url = components.url else { return nil }

        return LocalWebDriverAgentClient(baseURL: url, token: wdaToken)
    }
}
