import Testing
@testable import AgentCore

@Suite("Agent loop limits")
struct AgentLoopTests {
    @Test("stops after the maximum number of agent steps")
    func stopsAtMaxSteps() async {
        let limits = AgentLoopLimits(maxAgentSteps: 4, maxJSONRepairAttempts: 3, maxActionRetries: 2, maxRecoveryAttempts: 2)
        let loop = AgentLoop(
            configuration: AgentLoopConfiguration(
                limits: limits,
                observer: InAppObserver(visibleText: ["Ready"]),
                planner: ConstantPlanner(plan: AgentPlan(
                    summary: "Keep waiting",
                    steps: [AgentStep(action: .wait(seconds: 0), rationale: "Stay in the loop")]
                )),
                executor: PlanningOnlyActionExecutor(),
                goalVerifier: NeverSatisfiedGoalVerifier(),
                approval: AutoApprovingHandler(),
                allowedModes: [.inApp]
            )
        )

        let snapshot = await loop.run(goal: "Never finish")
        #expect(snapshot.phase == .failed)
        #expect(snapshot.agentStepCount == 4)
        #expect(snapshot.outcomeMessage?.contains("maximum") == true)
    }

    @Test("retries a transient action failure within the retry budget")
    func retriesTransientFailures() async {
        let executor = FlakyExecutor(failCount: 2, failMessage: "timed out")
        let loop = AgentLoop(
            configuration: AgentLoopConfiguration(
                limits: AgentLoopLimits(maxAgentSteps: 8, maxActionRetries: 2, maxRecoveryAttempts: 2),
                observer: InAppObserver(),
                planner: ConstantPlanner(plan: AgentPlan(
                    summary: "Answer",
                    steps: [AgentStep(action: .answer("ok"), rationale: "Finish")]
                )),
                executor: executor,
                approval: AutoApprovingHandler(),
                allowedModes: [.inApp]
            )
        )

        let snapshot = await loop.run(goal: "Say ok")
        #expect(snapshot.phase == .completed)
        #expect(await executor.attempts() == 3)
    }

    @Test("stops after the recovery budget is exhausted")
    func stopsAfterRecoveryBudget() async {
        let loop = AgentLoop(
            configuration: AgentLoopConfiguration(
                limits: AgentLoopLimits(maxAgentSteps: 8, maxActionRetries: 0, maxRecoveryAttempts: 2),
                observer: InAppObserver(),
                planner: ConstantPlanner(plan: AgentPlan(
                    summary: "Tap",
                    steps: [AgentStep(action: .tap(controlId: "missing"), rationale: "Wrong target")]
                )),
                executor: FailingExecutor(message: "Control not found"),
                approval: AutoApprovingHandler(),
                allowedModes: [.inApp]
            )
        )

        let snapshot = await loop.run(goal: "Tap a missing control")
        #expect(snapshot.phase == .failed || snapshot.phase == .blocked)
        #expect((snapshot.lastRecovery?.classification == .impossible) || snapshot.phase == .failed)
    }

    @Test("completes a simple in-app goal")
    func completesInAppGoal() async {
        let loop = AgentLoop(
            configuration: AgentLoopConfiguration(
                observer: InAppObserver(appContext: "PrivateAgent"),
                planner: RuleBasedAgentPlanner(),
                executor: PlanningOnlyActionExecutor(),
                approval: AutoApprovingHandler(),
                allowedModes: [.inApp]
            )
        )

        let snapshot = await loop.run(goal: "Summarize this conversation")
        #expect(snapshot.phase == .completed)
        #expect(!snapshot.stepRecords.isEmpty)
        #expect(snapshot.stepRecords[0].execution.status == .completed)
    }

    @Test("cancel moves the loop to cancelled")
    func cancelStopsLoop() async {
        let gate = AgentApprovalBroker()
        let loop = AgentLoop(
            configuration: AgentLoopConfiguration(
                observer: InAppObserver(),
                planner: ConstantPlanner(plan: AgentPlan(
                    summary: "Needs approval",
                    steps: [
                        AgentStep(
                            action: .handoff(AgentHandoff(target: .macAssisted, reason: "External")),
                            rationale: "Needs Mac",
                            risk: .high,
                            requiresApproval: true
                        )
                    ],
                    requiresUserApproval: true,
                    risk: .high
                )),
                executor: PlanningOnlyActionExecutor(),
                policy: AgentPolicy(requireApprovalAtOrAbove: .high, autoApproveInAppAnswers: false),
                approval: gate,
                allowedModes: [.inApp, .macAssisted]
            )
        )

        async let snapshot = loop.run(goal: "Control another app")
        try? await Task.sleep(nanoseconds: 50_000_000)
        await loop.cancel()
        let result = await snapshot
        #expect(result.phase == .cancelled || result.phase == .blocked)
    }
}

private struct ConstantPlanner: AgentPlanning {
    var plan: AgentPlan

    func makePlan(for observation: AgentObservation, allowedModes: [AutomationMode]) async throws -> AgentPlan {
        _ = observation
        _ = allowedModes
        return plan
    }
}

private struct NeverSatisfiedGoalVerifier: GoalVerifying {
    func verify(goal: String, observation: AgentObservation, history: [StepRunRecord]) -> GoalVerificationResult {
        _ = goal
        _ = observation
        _ = history
        return GoalVerificationResult(isSatisfied: false, message: "Never done")
    }
}

private actor AttemptCounter {
    var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
    func current() -> Int { value }
}

private struct FlakyExecutor: AgentActionExecuting {
    let failCount: Int
    let failMessage: String
    let counter = AttemptCounter()

    func canExecute(_ action: AgentAction) -> Bool { true }

    func execute(_ action: AgentAction) async throws -> ActionExecutionResult {
        let attempt = await counter.increment()
        if attempt <= failCount {
            return ActionExecutionResult(action: action, status: .failed, message: failMessage)
        }
        return ActionExecutionResult(action: action, status: .completed, message: "ok")
    }

    func attempts() async -> Int {
        await counter.current()
    }
}

private struct FailingExecutor: AgentActionExecuting {
    var message: String

    func canExecute(_ action: AgentAction) -> Bool { true }

    func execute(_ action: AgentAction) async throws -> ActionExecutionResult {
        ActionExecutionResult(action: action, status: .failed, message: message)
    }
}
