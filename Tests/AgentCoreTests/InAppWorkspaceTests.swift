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
        #expect(result.message.contains("screen=models") || result.message.contains("screen=agentMode") || result.message.contains("screen="))
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
}
