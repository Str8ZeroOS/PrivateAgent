import Foundation
import Observation
import AgentCore
import FlashMoEBridge
#if os(iOS)
import UIKit
#endif

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
    public var bridgeHost: String = UserDefaults.standard.string(forKey: BridgePairingStore.hostKey) ?? PrivateAgentLAN.macHost
    public var bridgePort: String = UserDefaults.standard.string(forKey: BridgePairingStore.portKey) ?? String(PrivateAgentLAN.bridgePort)
    /// One-time 6-digit code shown in the bridge window. Never persisted.
    public var pairingCode: String = ""
    public var wdaHost: String = UserDefaults.standard.string(forKey: BridgePairingStore.wdaHostKey) ?? "127.0.0.1"
    public var wdaPort: String = UserDefaults.standard.string(forKey: BridgePairingStore.wdaPortKey) ?? "8101"
    public private(set) var bridgeConnection: BridgeConnectionStatus?
    public private(set) var wdaConnection: WDAConnectionStatus?
    public private(set) var isCheckingBridge = false
    public private(set) var isCheckingWDA = false
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
    /// Bridge tokens live only here (the Keychain on device), never in UserDefaults.
    private let secrets: any CredentialStore
    private let transport: any HTTPTransport
    private let wdaSessionStore: any CredentialStore
    @ObservationIgnored private var wdaManager: WebDriverAgentSessionManager?

    public init(
        session: AgentSession = AgentSession(),
        runner: PlanRunner = PlanRunner(executor: SystemActionExecutorFactory.makeDefaultExecutor()),
        secrets: any CredentialStore = CredentialStores.secure(),
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        wdaSessionStore: any CredentialStore = UserDefaultsCredentialStore()
    ) {
        self.session = session
        self.runner = runner
        self.secrets = secrets
        self.transport = transport
        self.wdaSessionStore = wdaSessionStore
        reloadPairing()
    }

    /// Outcome-first summary of the last Agent Mode run (rule-based or local
    /// model), or of "Run Plan Once". Nil while nothing has run or when the
    /// answer-style setting is off.
    public var runSummary: AgentRunSummary? {
        guard AssistantStylePreferences.isEnabled() else { return nil }
        if let loopSnapshot, loopSnapshot.phase != .idle {
            return AgentRunSummaryFormatter.summarize(loopSnapshot)
        }
        if let plan, !executionResults.isEmpty {
            return AgentRunSummaryFormatter.summarize(plan: plan, results: executionResults)
        }
        return nil
    }

    /// Short status line for the bridge (kept for callers that want a string).
    public var bridgeStatus: String? { bridgeConnection?.summary }
    public var wdaStatus: String? { wdaConnection?.summary }

    public func reloadPairing() {
        BridgePairingStore.migrateLegacyTokens(secrets: secrets)
        let defaults = UserDefaults.standard
        if let host = defaults.string(forKey: BridgePairingStore.hostKey), !host.isEmpty { bridgeHost = host }
        if let port = defaults.string(forKey: BridgePairingStore.portKey), !port.isEmpty { bridgePort = port }
        if let pairing = BridgePairing.fromEnvironment(ProcessInfo.processInfo.environment) {
            apply(pairing)
        }
    }

    /// Applies a legacy token pairing (old `privateagent://pair?token=` link or
    /// environment). The token is written to the Keychain, not UserDefaults.
    public func apply(_ pairing: BridgePairing) {
        bridgeHost = pairing.host
        bridgePort = String(pairing.port)
        wdaHost = pairing.wdaHost
        wdaPort = String(pairing.wdaPort)
        allowedModes = pairing.recommendedModes(startingFrom: allowedModes)
        BridgePairingStore.save(pairing, secrets: secrets)
        saveBridgeSettings()
        bridgeConnection = nil
    }

    /// Picks up a `privateagent://pair?...&code=` link and runs the handshake.
    public func handlePendingPairing(_ pending: PendingBridgePairing) async {
        bridgeHost = pending.host
        bridgePort = String(pending.port)
        pairingCode = pending.code
        await checkBridgeHealth()
    }

    public func updateGoal(_ goal: String) {
        self.goal = goal
    }

    public func saveBridgeSettings() {
        let defaults = UserDefaults.standard
        defaults.set(bridgeHost.trimmingCharacters(in: .whitespacesAndNewlines), forKey: BridgePairingStore.hostKey)
        defaults.set(bridgePort.trimmingCharacters(in: .whitespacesAndNewlines), forKey: BridgePairingStore.portKey)
        defaults.set(wdaHost.trimmingCharacters(in: .whitespacesAndNewlines), forKey: BridgePairingStore.wdaHostKey)
        defaults.set(wdaPort.trimmingCharacters(in: .whitespacesAndNewlines), forKey: BridgePairingStore.wdaPortKey)
        // Tokens are never written to UserDefaults; drop any legacy copies.
        defaults.removeObject(forKey: BridgePairingStore.tokenKey)
        defaults.removeObject(forKey: BridgePairingStore.wdaTokenKey)
    }

    /// "Check Bridge": probe /health with the Keychain token. If the bridge is
    /// reachable but unpaired (or the token was rejected) and a pairing code was
    /// entered, run the /pair handshake and store the issued token.
    public func checkBridgeHealth() async {
        saveBridgeSettings()
        errorMessage = nil
        guard let manager = makeBridgeManager() else {
            bridgeConnection = BridgeConnectionStatus(
                state: .notConfigured,
                title: "Not configured",
                detail: "Enter the bridge computer's IP address and a port between 1 and 65535.",
                hint: "Example: 192.168.12.141 and 8765."
            )
            return
        }
        isCheckingBridge = true
        defer { isCheckingBridge = false }

        var status = await manager.checkStatus()
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if status.needsPairingCode, !code.isEmpty {
            status = await manager.pair(code: code, deviceName: Self.deviceName)
        }
        if status.state == .paired {
            pairingCode = ""
            if !allowedModes.contains(.macAssisted) {
                allowedModes.append(.macAssisted)
            }
        }
        bridgeConnection = status
    }

    /// Explicit "Pair" button: send the code even before a status check.
    public func pairBridge() async {
        saveBridgeSettings()
        errorMessage = nil
        guard let manager = makeBridgeManager() else {
            await checkBridgeHealth()
            return
        }
        isCheckingBridge = true
        defer { isCheckingBridge = false }
        let status = await manager.pair(code: pairingCode, deviceName: Self.deviceName)
        if status.state == .paired {
            pairingCode = ""
            if !allowedModes.contains(.macAssisted) {
                allowedModes.append(.macAssisted)
            }
        }
        bridgeConnection = status
    }

    /// Deletes this bridge's token from the Keychain and re-checks.
    public func forgetBridgePairing() async {
        makeBridgeManager()?.forgetToken()
        await checkBridgeHealth()
    }

    public var hasStoredBridgeToken: Bool {
        makeBridgeManager()?.storedToken() != nil
    }

    /// "Check WDA": probe /status, then create or reuse a WebDriver session
    /// (recreating it if the stored one expired). For 127.0.0.1 it also tries
    /// the on-device WebDriverAgentRunner port 8100.
    public func checkWDAStatus() async {
        saveBridgeSettings()
        errorMessage = nil
        let trimmedHost = wdaHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, let port = Int(wdaPort.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(port) else {
            wdaConnection = WDAConnectionStatus(
                state: .notConfigured,
                title: "Not configured",
                detail: "Enter the WebDriverAgent host and a port between 1 and 65535.",
                hint: "On-device WebDriverAgentRunner: 127.0.0.1 and 8100.",
                host: trimmedHost,
                port: 0
            )
            return
        }
        isCheckingWDA = true
        defer { isCheckingWDA = false }

        let (status, manager) = await WebDriverAgentProbe.check(
            host: trimmedHost,
            port: port,
            transport: transport,
            sessionStore: wdaSessionStore,
            tokenStore: secrets
        )
        wdaManager = manager
        if status.port != port, status.state != .unreachable {
            wdaPort = String(status.port)
            saveBridgeSettings()
        }
        wdaConnection = status
    }

    /// Drops the stored WDA session and creates a fresh one.
    public func resetWDASession() async {
        if let manager = currentWDAManager() {
            await manager.invalidateSession()
        }
        await checkWDAStatus()
    }

    private static var deviceName: String {
        #if os(iOS)
        return "Str8ZeRO on \(UIDevice.current.model)"
        #else
        return "Str8ZeRO"
        #endif
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
                let planner = LLMAgentPlanner(
                    generator: generator,
                    promptCompiler: AgentPromptCompiler(answerStyleEnabled: AssistantStylePreferences.isEnabled())
                )
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
        loopSnapshot = nil
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
                promptCompiler: AgentPromptCompiler(answerStyleEnabled: AssistantStylePreferences.isEnabled()),
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

    private func makeBridgeManager() -> BridgeConnectionManager? {
        let trimmedHost = bridgeHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPort = bridgePort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, let port = Int(trimmedPort), (1...65535).contains(port) else { return nil }
        let manager = BridgeConnectionManager(host: trimmedHost, port: port, transport: transport, tokenStore: secrets)
        return manager.baseURL == nil ? nil : manager
    }

    private func makeBridgeClient() -> LocalBridgeClient? {
        makeBridgeManager()?.makeClient()
    }

    private func currentWDAManager() -> WebDriverAgentSessionManager? {
        let trimmedHost = wdaHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, let port = Int(wdaPort.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(port) else {
            return nil
        }
        if let wdaManager, wdaManager.host == trimmedHost, wdaManager.port == port {
            return wdaManager
        }
        let manager = WebDriverAgentSessionManager(
            host: trimmedHost, port: port, transport: transport,
            sessionStore: wdaSessionStore, tokenStore: secrets
        )
        wdaManager = manager
        return manager
    }

    private func makeWDAClient() -> ManagedWebDriverAgentClient? {
        guard let manager = currentWDAManager() else { return nil }
        return ManagedWebDriverAgentClient(manager: manager, transport: transport, tokenStore: secrets)
    }
}
