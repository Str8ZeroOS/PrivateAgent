import Testing
@testable import AgentCore

@Suite("In-app workspace and App Intents")
struct InAppWorkspaceTests {
    @Test("workspace observation exposes first-party controls")
    func workspaceObservationHasControls() {
        let observation = InAppWorkspace.observation(goal: "Open models", screen: .agentMode)
        #expect(observation.source == .privateAgentApp)
        #expect(observation.controls.contains(where: { $0.id == "agent.run" }))
        #expect(observation.controls.contains(where: { $0.id == "nav.models" }))
        #expect(observation.appContext == "PrivateAgent.agentMode")
    }

    @Test("in-app executor activates a workspace control")
    func tapsWorkspaceControl() async throws {
        let result = try await InAppActionExecutor().execute(.tap(controlId: "nav.models"))
        #expect(result.status == .completed)
        #expect(result.message.contains("Models"))
        #expect(result.message.contains("screen=models"))
    }

    @Test("App Intent executor invokes a first-party intent")
    func invokesFirstPartyIntent() async throws {
        let executor = AppIntentActionExecutor()
        #expect(executor.canExecute(.invokeAppIntent("OpenModelManager")))
        #expect(!executor.canExecute(.openURL("https://example.com")))

        let result = try await executor.execute(.invokeAppIntent("OpenModelManager"))
        #expect(result.status == .completed)
        #expect(result.message.contains("OpenModelManager"))
    }

    @Test("rule-based planner uses first-party intents for model manager")
    func plannerUsesAppIntentForModels() async throws {
        let planner = RuleBasedAgentPlanner()
        let observation = InAppWorkspace.observation(goal: "Open the model manager")
        let plan = try await planner.makePlan(for: observation, allowedModes: [.inApp, .appIntents])

        #expect(plan.requiresUserApproval == false)
        guard case .invokeAppIntent(let name) = plan.steps[0].action else {
            Issue.record("Expected invokeAppIntent")
            return
        }
        #expect(name == "OpenModelManager")
    }

    @Test("validator allows tap on an observed in-app control")
    func validatorAllowsInAppTap() {
        let observation = InAppWorkspace.observation(goal: "Open models")
        let plan = AgentPlan(
            summary: "Open models",
            steps: [AgentStep(action: .tap(controlId: "nav.models"), rationale: "First-party control")]
        )
        let result = PlanValidator().validate(
            plan,
            observation: observation,
            allowedModes: [.inApp],
            executor: InAppActionExecutor()
        )
        #expect(result.isValid)
        #expect(!result.requiresApproval)
    }

    @Test("observer follows an in-app navigation result")
    func observerFollowsNavigation() async throws {
        let observer = InAppObserver()
        let observation = try await observer.observe(
            goal: "Open models",
            context: AgentObservationContext(
                lastResult: ActionExecutionResult(
                    action: .invokeAppIntent("OpenModelManager"),
                    status: .completed,
                    message: "Invoked first-party App Intent OpenModelManager. screen=models"
                )
            )
        )
        #expect(observation.appContext == "PrivateAgent.models")
        #expect(observation.visibleText.contains("Model Manager"))
    }

    @Test("workspace store is a live snapshot after navigation")
    func storeTracksNavigation() async {
        let store = InAppWorkspaceStore(screen: .agentMode)
        let before = await store.snapshot(goal: "Open models")
        #expect(before.appContext == "PrivateAgent.agentMode")

        let result = await store.perform(.invokeIntent("OpenModelManager"))
        #expect(result.succeeded)
        #expect(result.screen == .models)

        let after = await store.snapshot(goal: "Open models")
        #expect(after.appContext == "PrivateAgent.models")
        #expect(after.visibleText.contains("Model Manager"))
        #expect(after.controls.contains(where: { $0.id == "models.download" }))
    }

    @Test("live observer reads the store instead of a static catalog")
    func liveObserverReadsStore() async throws {
        let store = InAppWorkspaceStore(screen: .chats)
        _ = await store.perform(.tap(controlId: "nav.settings"))
        let observation = try await LiveWorkspaceObserver(store: store).observe(
            goal: "Open settings",
            context: AgentObservationContext()
        )
        #expect(observation.appContext == "PrivateAgent.settings")
        #expect(observation.controls.contains(where: { $0.id == "settings.cloudToggle" }))
    }

    @Test("closed loop can open the model manager through the live store")
    func loopOpensModelManager() async {
        let store = InAppWorkspaceStore(screen: .agentMode)
        let loop = AgentLoop(
            configuration: AgentLoopConfiguration(
                observer: LiveWorkspaceObserver(store: store),
                planner: RuleBasedAgentPlanner(),
                executor: InAppActionExecutor(navigator: store),
                approval: AutoApprovingHandler(),
                allowedModes: [.inApp, .appIntents]
            )
        )
        let snapshot = await loop.run(goal: "Open the model manager")
        #expect(snapshot.phase == .completed)
        #expect(await store.currentScreen() == .models)
    }
}
