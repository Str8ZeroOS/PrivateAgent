import Foundation

public enum FailureClass: String, Sendable, Codable, Equatable {
    case transient
    case wrongTarget
    case permission
    case unavailableCapability
    case impossible
}

public enum RecoveryStrategy: Sendable, Codable, Equatable {
    case retry
    case reobserve
    case guideUser(String)
    case fallback(AgentAction)
    case stop(String)
}

public struct RecoveryDecision: Sendable, Codable, Equatable {
    public var classification: FailureClass
    public var strategy: RecoveryStrategy
    public var message: String

    public init(classification: FailureClass, strategy: RecoveryStrategy, message: String) {
        self.classification = classification
        self.strategy = strategy
        self.message = message
    }
}

public protocol RecoveryClassifying: Sendable {
    func classify(
        result: ActionExecutionResult,
        verification: StepVerificationResult?,
        step: AgentStep,
        allowedModes: [AutomationMode],
        retryCount: Int,
        recoveryCount: Int,
        limits: AgentLoopLimits
    ) -> RecoveryDecision
}

public struct RecoveryEngine: RecoveryClassifying {
    public init() {}

    public func classify(
        result: ActionExecutionResult,
        verification: StepVerificationResult?,
        step: AgentStep,
        allowedModes: [AutomationMode],
        retryCount: Int,
        recoveryCount: Int,
        limits: AgentLoopLimits
    ) -> RecoveryDecision {
        if recoveryCount >= limits.maxRecoveryAttempts {
            return RecoveryDecision(
                classification: .impossible,
                strategy: .stop("Recovery attempts exhausted."),
                message: "The agent reached the recovery limit without completing the step."
            )
        }

        let haystack = ((result.message) + " " + (verification?.message ?? "")).lowercased()

        if looksPermission(haystack) {
            return RecoveryDecision(
                classification: .permission,
                strategy: .guideUser("Grant the required permission or approval, then retry."),
                message: result.message
            )
        }

        if result.status == .skipped || looksUnavailable(haystack) {
            if let fallback = CapabilityFallback.alternateActions(for: step.action, allowedModes: allowedModes).first {
                return RecoveryDecision(
                    classification: .unavailableCapability,
                    strategy: .fallback(fallback),
                    message: "Primary capability is unavailable; trying an alternate executor."
                )
            }
            return RecoveryDecision(
                classification: .unavailableCapability,
                strategy: .stop("No alternate capability is available on this device."),
                message: result.message
            )
        }

        if looksWrongTarget(haystack) || verification?.outcome == .actionUnverified {
            return RecoveryDecision(
                classification: .wrongTarget,
                strategy: .reobserve,
                message: "The target or expected result did not match the latest observation."
            )
        }

        if looksTransient(haystack) && retryCount < limits.maxActionRetries {
            return RecoveryDecision(
                classification: .transient,
                strategy: .retry,
                message: "Transient failure; retrying the same action."
            )
        }

        if result.status == .failed && retryCount < limits.maxActionRetries {
            return RecoveryDecision(
                classification: .transient,
                strategy: .retry,
                message: "Action failed; retrying within the retry budget."
            )
        }

        return RecoveryDecision(
            classification: .impossible,
            strategy: .stop(result.message),
            message: "The failure cannot be recovered automatically."
        )
    }

    private func looksPermission(_ message: String) -> Bool {
        containsAny(message, ["permission", "denied", "unauthorized", "not authorized", "privacy", "access denied"])
    }

    private func looksUnavailable(_ message: String) -> Bool {
        containsAny(message, ["unavailable", "no executor", "not registered", "unsupported", "skipped"])
    }

    private func looksWrongTarget(_ message: String) -> Bool {
        containsAny(message, ["not found", "no such control", "stale", "missing", "does not exist", "unverified", "wrong target"])
    }

    private func looksTransient(_ message: String) -> Bool {
        containsAny(message, ["timeout", "timed out", "temporarily", "network", "busy", "try again", "503", "429"])
    }

    private func containsAny(_ message: String, _ needles: [String]) -> Bool {
        needles.contains { message.contains($0) }
    }
}
