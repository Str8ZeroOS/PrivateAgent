import Foundation

public struct AgentLoopLimits: Sendable, Codable, Equatable {
    public var maxAgentSteps: Int
    public var maxJSONRepairAttempts: Int
    public var maxActionRetries: Int
    public var maxRecoveryAttempts: Int

    public static let `default` = AgentLoopLimits(
        maxAgentSteps: 32,
        maxJSONRepairAttempts: 3,
        maxActionRetries: 2,
        maxRecoveryAttempts: 2
    )

    public init(
        maxAgentSteps: Int = 32,
        maxJSONRepairAttempts: Int = 3,
        maxActionRetries: Int = 2,
        maxRecoveryAttempts: Int = 2
    ) {
        self.maxAgentSteps = max(1, maxAgentSteps)
        self.maxJSONRepairAttempts = max(0, maxJSONRepairAttempts)
        self.maxActionRetries = max(0, maxActionRetries)
        self.maxRecoveryAttempts = max(0, maxRecoveryAttempts)
    }
}

public enum AgentLoopEvent: Sendable, Equatable {
    case phaseChanged(AgentPhase)
    case observation(AgentObservation)
    case planUpdated(AgentPlan)
    case validation(PlanValidationResult)
    case awaitingApproval(AgentApprovalRequest)
    case stepStarted(AgentStep)
    case actionResult(ActionExecutionResult)
    case verification(StepVerificationResult)
    case recovery(RecoveryDecision)
}

public struct AgentLoopSnapshot: Sendable, Codable, Equatable {
    public var phase: AgentPhase
    public var goal: String
    public var agentStepCount: Int
    public var observation: AgentObservation?
    public var plan: AgentPlan?
    public var validationIssues: [String]
    public var pendingApproval: AgentApprovalRequest?
    public var stepRecords: [StepRunRecord]
    public var lastRecovery: RecoveryDecision?
    public var outcomeMessage: String?
    public var plannerDiagnostics: AgentPlannerDiagnostics?

    public init(
        phase: AgentPhase = .idle,
        goal: String = "",
        agentStepCount: Int = 0,
        observation: AgentObservation? = nil,
        plan: AgentPlan? = nil,
        validationIssues: [String] = [],
        pendingApproval: AgentApprovalRequest? = nil,
        stepRecords: [StepRunRecord] = [],
        lastRecovery: RecoveryDecision? = nil,
        outcomeMessage: String? = nil,
        plannerDiagnostics: AgentPlannerDiagnostics? = nil
    ) {
        self.phase = phase
        self.goal = goal
        self.agentStepCount = agentStepCount
        self.observation = observation
        self.plan = plan
        self.validationIssues = validationIssues
        self.pendingApproval = pendingApproval
        self.stepRecords = stepRecords
        self.lastRecovery = lastRecovery
        self.outcomeMessage = outcomeMessage
        self.plannerDiagnostics = plannerDiagnostics
    }
}

public struct AgentLoopConfiguration: Sendable {
    public var limits: AgentLoopLimits
    public var observer: any AgentObserving
    public var planner: any AgentPlanning
    public var validator: any PlanValidating
    public var executor: any AgentActionExecuting
    public var actionVerifier: any ActionVerifying
    public var goalVerifier: any GoalVerifying
    public var recovery: any RecoveryClassifying
    public var policy: AgentPolicy
    public var approval: any AgentApprovalHandling
    public var allowedModes: [AutomationMode]
    public var eventHandler: (@Sendable (AgentLoopEvent) async -> Void)?

    public init(
        limits: AgentLoopLimits = .default,
        observer: any AgentObserving,
        planner: any AgentPlanning,
        validator: any PlanValidating = PlanValidator(),
        executor: any AgentActionExecuting,
        actionVerifier: any ActionVerifying = ActionVerifier(),
        goalVerifier: any GoalVerifying = GoalVerifier(),
        recovery: any RecoveryClassifying = RecoveryEngine(),
        policy: AgentPolicy = .default,
        approval: any AgentApprovalHandling = AutoApprovingHandler(),
        allowedModes: [AutomationMode] = [.inApp, .appIntents, .shortcuts],
        eventHandler: (@Sendable (AgentLoopEvent) async -> Void)? = nil
    ) {
        self.limits = limits
        self.observer = observer
        self.planner = planner
        self.validator = validator
        self.executor = executor
        self.actionVerifier = actionVerifier
        self.goalVerifier = goalVerifier
        self.recovery = recovery
        self.policy = policy
        self.approval = approval
        self.allowedModes = allowedModes
        self.eventHandler = eventHandler
    }
}

public actor AgentLoop {
    private var cancelled = false
    private var machine = AgentStateMachine()
    private var snapshot = AgentLoopSnapshot()
    private let configuration: AgentLoopConfiguration

    public init(configuration: AgentLoopConfiguration) {
        self.configuration = configuration
    }

    public func currentSnapshot() -> AgentLoopSnapshot {
        snapshot
    }

    public func cancel() async {
        cancelled = true
        if let broker = configuration.approval as? AgentApprovalBroker {
            await broker.respond(.cancelled)
        }
    }

    public func run(goal: String) async -> AgentLoopSnapshot {
        cancelled = false
        machine = AgentStateMachine()
        snapshot = AgentLoopSnapshot(goal: goal)

        do {
            try await transition(to: .understanding)
            let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                snapshot.outcomeMessage = "Ask for a task before acting."
                try await transition(to: .blocked)
                return snapshot
            }

            var observation = try await observe(goal: trimmed, lastAction: nil, lastResult: nil)
            var recoveryCount = 0
            var retryCount = 0
            var pendingFallback: AgentAction?

            for stepIndex in 1...configuration.limits.maxAgentSteps {
                if Task.isCancelled || cancelled {
                    try await finish(.cancelled, message: "Run cancelled.")
                    return snapshot
                }

                snapshot.agentStepCount = stepIndex
                try await transition(to: .planning)
                let plan = try await configuration.planner.makePlan(for: observation, allowedModes: configuration.allowedModes)
                snapshot.plan = plan
                await emit(.planUpdated(plan))

                try await transition(to: .validating)
                let validation = configuration.validator.validate(
                    plan,
                    observation: observation,
                    allowedModes: configuration.allowedModes,
                    executor: configuration.executor
                )
                snapshot.validationIssues = validation.issues.map(\.message)
                await emit(.validation(validation))

                if !validation.isValid {
                    recoveryCount += 1
                    let decision = RecoveryDecision(
                        classification: .wrongTarget,
                        strategy: recoveryCount > configuration.limits.maxRecoveryAttempts ? .stop("Validation failed.") : .reobserve,
                        message: validation.errorMessages.joined(separator: " ")
                    )
                    snapshot.lastRecovery = decision
                    await emit(.recovery(decision))
                    if recoveryCount > configuration.limits.maxRecoveryAttempts {
                        try await finish(.failed, message: decision.message)
                        return snapshot
                    }
                    try await transition(to: .recovering)
                    observation = try await observe(goal: trimmed, lastAction: nil, lastResult: nil)
                    continue
                }

                let policyDecision = configuration.policy.decision(for: plan, validation: validation)
                switch policyDecision {
                case .deny(let reason):
                    try await finish(.blocked, message: reason)
                    return snapshot
                case .requireApproval(let reason):
                    let request = AgentApprovalRequest(plan: plan, reason: reason, risk: plan.risk)
                    snapshot.pendingApproval = request
                    try await transition(to: .awaitingApproval)
                    await emit(.awaitingApproval(request))
                    let decision = await configuration.approval.decide(request)
                    snapshot.pendingApproval = nil
                    switch decision {
                    case .approved:
                        break
                    case .rejected:
                        try await finish(.blocked, message: "User rejected the plan.")
                        return snapshot
                    case .cancelled:
                        try await finish(.cancelled, message: "Run cancelled during approval.")
                        return snapshot
                    }
                case .allow:
                    break
                }

                guard let step = plan.steps.first else {
                    try await finish(.failed, message: "Validated plan had no steps.")
                    return snapshot
                }

                let action = pendingFallback ?? step.action
                pendingFallback = nil
                var currentStep = step
                currentStep.action = action
                currentStep.status = .running
                await emit(.stepStarted(currentStep))

                try await transition(to: .executing)
                let execution: ActionExecutionResult
                if let router = configuration.executor as? ActionExecutorRouter {
                    execution = try await router.executeWithFallback(action, allowedModes: configuration.allowedModes)
                } else {
                    execution = try await configuration.executor.execute(action)
                }
                await emit(.actionResult(execution))

                try await transition(to: .verifying)
                observation = try await observe(goal: trimmed, lastAction: action, lastResult: execution)
                let verification = configuration.actionVerifier.verify(
                    step: currentStep,
                    execution: execution,
                    observation: observation
                )
                await emit(.verification(verification))

                let outcome: ActionOutcome
                if execution.status == .skipped {
                    outcome = .skipped
                } else if execution.status != .completed {
                    outcome = .actionFailed
                } else {
                    outcome = verification.outcome
                }

                let record = StepRunRecord(
                    step: currentStep,
                    execution: execution,
                    verification: verification,
                    outcome: outcome,
                    usedFallback: action != step.action
                )
                snapshot.stepRecords.append(record)

                let goalResult = configuration.goalVerifier.verify(
                    goal: trimmed,
                    observation: observation,
                    history: snapshot.stepRecords
                )
                if goalResult.isSatisfied {
                    try await finish(.completed, message: goalResult.message)
                    return snapshot
                }

                let succeeded = execution.status == .completed && verification.outcome != .actionUnverified
                if succeeded {
                    retryCount = 0
                    recoveryCount = 0
                    try await transition(to: .observing)
                    continue
                }

                try await transition(to: .recovering)
                let recovery = configuration.recovery.classify(
                    result: execution,
                    verification: verification,
                    step: currentStep,
                    allowedModes: configuration.allowedModes,
                    retryCount: retryCount,
                    recoveryCount: recoveryCount,
                    limits: configuration.limits
                )
                snapshot.lastRecovery = recovery
                await emit(.recovery(recovery))

                switch recovery.strategy {
                case .retry:
                    retryCount += 1
                    pendingFallback = action
                    observation = try await observe(goal: trimmed, lastAction: action, lastResult: execution)
                case .reobserve:
                    recoveryCount += 1
                    retryCount = 0
                    observation = try await observe(goal: trimmed, lastAction: action, lastResult: execution)
                case .fallback(let fallbackAction):
                    recoveryCount += 1
                    pendingFallback = fallbackAction
                    currentStep.action = fallbackAction
                case .guideUser(let guidance):
                    try await finish(.blocked, message: guidance)
                    return snapshot
                case .stop(let message):
                    try await finish(.failed, message: message)
                    return snapshot
                }
            }

            try await finish(.failed, message: "Reached the maximum of \(configuration.limits.maxAgentSteps) agent steps.")
            return snapshot
        } catch {
            if cancelled || Task.isCancelled {
                snapshot.phase = .cancelled
                snapshot.outcomeMessage = "Run cancelled."
                return snapshot
            }
            snapshot.phase = .failed
            snapshot.outcomeMessage = error.localizedDescription
            return snapshot
        }
    }

    private func observe(
        goal: String,
        lastAction: AgentAction?,
        lastResult: ActionExecutionResult?
    ) async throws -> AgentObservation {
        if machine.phase == .understanding || machine.phase == .recovering {
            try await transition(to: .observing)
        }
        let observation = try await configuration.observer.observe(
            goal: goal,
            context: AgentObservationContext(
                previous: snapshot.observation,
                lastAction: lastAction,
                lastResult: lastResult
            )
        )
        snapshot.observation = observation
        await emit(.observation(observation))
        return observation
    }

    private func finish(_ phase: AgentPhase, message: String) async throws {
        snapshot.outcomeMessage = message
        try await transition(to: phase)
    }

    private func transition(to phase: AgentPhase) async throws {
        if (cancelled || Task.isCancelled) && !phase.isTerminal {
            try machine.transition(to: .cancelled)
            snapshot.phase = .cancelled
            snapshot.outcomeMessage = snapshot.outcomeMessage ?? "Run cancelled."
            await emit(.phaseChanged(.cancelled))
            throw CancellationError()
        }
        try machine.transition(to: phase)
        snapshot.phase = phase
        await emit(.phaseChanged(phase))
    }

    private func emit(_ event: AgentLoopEvent) async {
        await configuration.eventHandler?(event)
    }
}

public final class AgentLoopEventBridge: @unchecked Sendable {
    private let handler: @MainActor (AgentLoopEvent) -> Void

    public init(handler: @escaping @MainActor (AgentLoopEvent) -> Void) {
        self.handler = handler
    }

    public func emit(_ event: AgentLoopEvent) async {
        await MainActor.run {
            handler(event)
        }
    }
}
