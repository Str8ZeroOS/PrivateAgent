import Testing
@testable import AgentCore

@Suite("Capability runtime")
struct CapabilityRuntimeTests {
    @Test("observer prefers a live Mac observation when that mode is allowed")
    func observerPrefersMac() async throws {
        let store = InAppWorkspaceStore(screen: .agentMode)
        let client = ScriptedMacClient(
            observation: AgentObservation(
                source: .macBridge,
                userGoal: "Tap Settings",
                visibleText: ["Settings"],
                controls: [AgentControl(id: "ax-0", label: "Settings", role: .button)],
                appContext: "Mac bridge helper"
            )
        )
        let observer = CapabilityObserver(
            allowedModes: [.inApp, .macAssisted],
            workspace: store,
            macClient: client
        )
        let observation = try await observer.observe(goal: "Tap Settings", context: AgentObservationContext())
        #expect(observation.source == .macBridge)
        #expect(observation.controls.contains(where: { $0.id == "ax-0" }))
    }

    @Test("observer falls back to the in-app store when adapters are down")
    func observerFallsBackToWorkspace() async throws {
        let store = InAppWorkspaceStore(screen: .settings)
        let observer = CapabilityObserver(
            allowedModes: [.inApp, .macAssisted],
            workspace: store,
            macClient: FailingMacClient()
        )
        let observation = try await observer.observe(goal: "Open settings", context: AgentObservationContext())
        #expect(observation.source == .privateAgentApp)
        #expect(observation.appContext == "PrivateAgent.settings")
    }

    @Test("closed loop taps a Mac-observed control through the composed runtime")
    func loopTapsMacControl() async {
        let store = InAppWorkspaceStore(screen: .agentMode)
        let client = ScriptedMacClient(
            observation: AgentObservation(
                source: .macBridge,
                userGoal: "Tap Settings",
                visibleText: ["Settings", "Safari"],
                controls: [AgentControl(id: "ax-0", label: "Settings", role: .button)],
                appContext: "Mac bridge helper"
            ),
            actionResponse: MacBridgeResponse(status: .completed, message: "Clicked AX control Settings")
        )
        let runtime = CapabilityRuntime.make(
            allowedModes: [.inApp, .macAssisted],
            navigator: store,
            workspace: store,
            macClient: client
        )
        let loop = AgentLoop(
            configuration: AgentLoopConfiguration(
                observer: runtime.observer,
                planner: RuleBasedAgentPlanner(),
                executor: runtime.executor,
                approval: AutoApprovingHandler(),
                allowedModes: [.inApp, .macAssisted]
            )
        )
        let snapshot = await loop.run(goal: "Tap Settings")
        #expect(snapshot.phase == .completed)
        #expect(await client.actionCount() == 1)
        #expect(snapshot.stepRecords.contains { record in
            if case .tap(let id) = record.step.action { return id == "ax-0" }
            return false
        })
    }
}

private actor MacActionCounter {
    var count = 0
    func increment() { count += 1 }
    func current() -> Int { count }
}

private struct ScriptedMacClient: MacBridgeClient {
    let observation: AgentObservation
    let actionResponse: MacBridgeResponse
    let counter = MacActionCounter()

    init(
        observation: AgentObservation,
        actionResponse: MacBridgeResponse = MacBridgeResponse(status: .completed, message: "ok")
    ) {
        self.observation = observation
        self.actionResponse = actionResponse
    }

    func requestObservation(_ request: MacBridgeObservationRequest) async throws -> MacBridgeResponse {
        _ = request
        return MacBridgeResponse(status: .completed, message: "Captured Mac bridge context.", observation: observation)
    }

    func executeAction(_ request: MacBridgeActionRequest) async throws -> MacBridgeResponse {
        _ = request
        await counter.increment()
        return actionResponse
    }

    func actionCount() async -> Int {
        await counter.current()
    }
}

private struct FailingMacClient: MacBridgeClient {
    func requestObservation(_ request: MacBridgeObservationRequest) async throws -> MacBridgeResponse {
        _ = request
        throw LocalBridgeClientError.invalidResponse
    }

    func executeAction(_ request: MacBridgeActionRequest) async throws -> MacBridgeResponse {
        _ = request
        throw LocalBridgeClientError.invalidResponse
    }
}
