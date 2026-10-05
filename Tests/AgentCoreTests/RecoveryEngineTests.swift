import Testing
@testable import AgentCore

@Suite("Recovery classification")
struct RecoveryEngineTests {
    private let limits = AgentLoopLimits.default
    private let step = AgentStep(action: .tap(controlId: "play"), rationale: "Tap play")

    @Test("classifies transient failures as retry")
    func transientRetry() {
        let decision = RecoveryEngine().classify(
            result: ActionExecutionResult(action: step.action, status: .failed, message: "Request timed out"),
            verification: nil,
            step: step,
            allowedModes: [.inApp, .macAssisted],
            retryCount: 0,
            recoveryCount: 0,
            limits: limits
        )
        #expect(decision.classification == .transient)
        #expect(decision.strategy == .retry)
    }

    @Test("classifies wrong targets as re-observe")
    func wrongTargetReobserve() {
        let decision = RecoveryEngine().classify(
            result: ActionExecutionResult(action: step.action, status: .failed, message: "Control not found"),
            verification: StepVerificationResult(outcome: .actionUnverified, verified: false, message: "unverified"),
            step: step,
            allowedModes: [.macAssisted],
            retryCount: 0,
            recoveryCount: 0,
            limits: limits
        )
        #expect(decision.classification == .wrongTarget)
        #expect(decision.strategy == .reobserve)
    }

    @Test("classifies permission failures as guide-user")
    func permissionGuidesUser() {
        let decision = RecoveryEngine().classify(
            result: ActionExecutionResult(action: step.action, status: .failed, message: "Permission denied for Accessibility"),
            verification: nil,
            step: step,
            allowedModes: [.macAssisted],
            retryCount: 0,
            recoveryCount: 0,
            limits: limits
        )
        #expect(decision.classification == .permission)
        guard case .guideUser = decision.strategy else {
            Issue.record("Expected guideUser")
            return
        }
    }

    @Test("classifies unavailable capability as fallback to Mac bridge")
    func unavailableFallsBack() {
        let decision = RecoveryEngine().classify(
            result: ActionExecutionResult(action: step.action, status: .skipped, message: "No executor is registered for this action."),
            verification: nil,
            step: step,
            allowedModes: [.inApp, .shortcuts, .macAssisted],
            retryCount: 0,
            recoveryCount: 0,
            limits: limits
        )
        #expect(decision.classification == .unavailableCapability)
        guard case .fallback(let action) = decision.strategy, case .handoff(let handoff) = action else {
            Issue.record("Expected Mac handoff fallback")
            return
        }
        #expect(handoff.target == .macAssisted)
    }

    @Test("stops when recovery attempts are exhausted")
    func stopsWhenRecoveryExhausted() {
        let decision = RecoveryEngine().classify(
            result: ActionExecutionResult(action: step.action, status: .failed, message: "still failing"),
            verification: nil,
            step: step,
            allowedModes: [.inApp],
            retryCount: 2,
            recoveryCount: 2,
            limits: limits
        )
        #expect(decision.classification == .impossible)
        guard case .stop = decision.strategy else {
            Issue.record("Expected stop")
            return
        }
    }
}
