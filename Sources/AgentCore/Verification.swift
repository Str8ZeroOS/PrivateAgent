import Foundation

public enum VerificationKind: String, Sendable, Codable, Equatable {
    case none
    case urlContains = "url_contains"
    case visibleTextContains = "visible_text_contains"
    case controlExists = "control_exists"
    case appContextContains = "app_context_contains"
    case statePredicate = "state_predicate"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "none":
            self = .none
        case "url_contains", "urlContains":
            self = .urlContains
        case "visible_text_contains", "visibleTextContains":
            self = .visibleTextContains
        case "control_exists", "controlExists":
            self = .controlExists
        case "app_context_contains", "appContextContains":
            self = .appContextContains
        case "state_predicate", "statePredicate":
            self = .statePredicate
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown verification kind '\(raw)'."
            )
        }
    }
}

public struct StatePredicate: Sendable, Codable, Equatable {
    public var visibleTextContains: String?
    public var appContextContains: String?
    public var controlId: String?

    public init(
        visibleTextContains: String? = nil,
        appContextContains: String? = nil,
        controlId: String? = nil
    ) {
        self.visibleTextContains = visibleTextContains
        self.appContextContains = appContextContains
        self.controlId = controlId
    }
}

public struct VerificationSpec: Sendable, Codable, Equatable {
    public var kind: VerificationKind
    public var value: String?
    public var predicate: StatePredicate?

    public static let none = VerificationSpec(kind: .none)

    public init(kind: VerificationKind, value: String? = nil, predicate: StatePredicate? = nil) {
        self.kind = kind
        self.value = value
        self.predicate = predicate
    }

    public static func urlContains(_ value: String) -> VerificationSpec {
        VerificationSpec(kind: .urlContains, value: value)
    }

    public static func visibleTextContains(_ value: String) -> VerificationSpec {
        VerificationSpec(kind: .visibleTextContains, value: value)
    }

    public static func controlExists(_ value: String) -> VerificationSpec {
        VerificationSpec(kind: .controlExists, value: value)
    }

    public static func appContextContains(_ value: String) -> VerificationSpec {
        VerificationSpec(kind: .appContextContains, value: value)
    }

    public static func statePredicate(_ predicate: StatePredicate) -> VerificationSpec {
        VerificationSpec(kind: .statePredicate, predicate: predicate)
    }
}

public enum ActionOutcome: String, Sendable, Codable, Equatable {
    case actionSuccess
    case actionVerified
    case actionUnverified
    case actionFailed
    case skipped

    public var title: String {
        switch self {
        case .actionSuccess: return "ACTION_SUCCESS"
        case .actionVerified: return "ACTION_VERIFIED"
        case .actionUnverified: return "ACTION_UNVERIFIED"
        case .actionFailed: return "ACTION_FAILED"
        case .skipped: return "SKIPPED"
        }
    }
}

public struct StepVerificationResult: Sendable, Codable, Equatable {
    public var outcome: ActionOutcome
    public var verified: Bool
    public var message: String

    public init(outcome: ActionOutcome, verified: Bool, message: String) {
        self.outcome = outcome
        self.verified = verified
        self.message = message
    }
}

public struct GoalVerificationResult: Sendable, Codable, Equatable {
    public var isSatisfied: Bool
    public var message: String

    public init(isSatisfied: Bool, message: String) {
        self.isSatisfied = isSatisfied
        self.message = message
    }
}

public struct StepRunRecord: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var step: AgentStep
    public var execution: ActionExecutionResult
    public var verification: StepVerificationResult?
    public var outcome: ActionOutcome
    public var usedFallback: Bool

    public init(
        id: UUID = UUID(),
        step: AgentStep,
        execution: ActionExecutionResult,
        verification: StepVerificationResult? = nil,
        outcome: ActionOutcome,
        usedFallback: Bool = false
    ) {
        self.id = id
        self.step = step
        self.execution = execution
        self.verification = verification
        self.outcome = outcome
        self.usedFallback = usedFallback
    }
}

public protocol ActionVerifying: Sendable {
    func verify(
        step: AgentStep,
        execution: ActionExecutionResult,
        observation: AgentObservation
    ) -> StepVerificationResult
}

public protocol GoalVerifying: Sendable {
    func verify(
        goal: String,
        observation: AgentObservation,
        history: [StepRunRecord]
    ) -> GoalVerificationResult
}

public struct ActionVerifier: ActionVerifying {
    public init() {}

    public func verify(
        step: AgentStep,
        execution: ActionExecutionResult,
        observation: AgentObservation
    ) -> StepVerificationResult {
        guard execution.status == .completed else {
            return StepVerificationResult(
                outcome: execution.status == .skipped ? .skipped : .actionFailed,
                verified: false,
                message: execution.message
            )
        }

        switch step.verification.kind {
        case .none:
            if let expected = step.expectedResult, !expected.isEmpty {
                if matches(expected, observation: observation) || execution.message.localizedCaseInsensitiveContains(expected) {
                    return StepVerificationResult(
                        outcome: .actionVerified,
                        verified: true,
                        message: "ACTION_VERIFIED: observation matches expected result."
                    )
                }
                return StepVerificationResult(
                    outcome: .actionUnverified,
                    verified: false,
                    message: "ACTION_SUCCESS from executor, but expected result was not observed."
                )
            }
            return StepVerificationResult(
                outcome: .actionSuccess,
                verified: false,
                message: "ACTION_SUCCESS: executor returned ok. No verification spec."
            )
        case .urlContains:
            let needle = step.verification.value ?? ""
            if case .openURL(let url) = step.action, url.localizedCaseInsensitiveContains(needle),
               execution.message.localizedCaseInsensitiveContains(needle) || matches(needle, observation: observation) {
                return verified("URL contains '\(needle)'.")
            }
            if matches(needle, observation: observation) || execution.message.localizedCaseInsensitiveContains(needle) {
                return verified("URL/observation contains '\(needle)'.")
            }
            return unverified("Observation does not contain '\(needle)'.")
        case .visibleTextContains:
            let needle = step.verification.value ?? ""
            if observation.visibleText.contains(where: { $0.localizedCaseInsensitiveContains(needle) })
                || execution.message.localizedCaseInsensitiveContains(needle) {
                return verified("Visible text contains '\(needle)'.")
            }
            return unverified("Visible text does not contain '\(needle)'.")
        case .controlExists:
            let id = step.verification.value ?? ""
            if observation.controls.contains(where: { $0.id == id || $0.label.localizedCaseInsensitiveContains(id) }) {
                return verified("Control '\(id)' is present.")
            }
            return unverified("Control '\(id)' is not in the current observation.")
        case .appContextContains:
            let needle = step.verification.value ?? ""
            if observation.appContext?.localizedCaseInsensitiveContains(needle) == true {
                return verified("App context contains '\(needle)'.")
            }
            return unverified("App context does not contain '\(needle)'.")
        case .statePredicate:
            let predicate = step.verification.predicate ?? StatePredicate()
            if matches(predicate, observation: observation) {
                return verified("State predicate matched.")
            }
            return unverified("State predicate did not match the current observation.")
        }
    }

    private func verified(_ message: String) -> StepVerificationResult {
        StepVerificationResult(outcome: .actionVerified, verified: true, message: "ACTION_VERIFIED: \(message)")
    }

    private func unverified(_ message: String) -> StepVerificationResult {
        StepVerificationResult(outcome: .actionUnverified, verified: false, message: "ACTION_UNVERIFIED: \(message)")
    }

    private func matches(_ needle: String, observation: AgentObservation) -> Bool {
        if observation.visibleText.contains(where: { $0.localizedCaseInsensitiveContains(needle) }) {
            return true
        }
        if observation.appContext?.localizedCaseInsensitiveContains(needle) == true {
            return true
        }
        if observation.controls.contains(where: { $0.label.localizedCaseInsensitiveContains(needle) || $0.id.localizedCaseInsensitiveContains(needle) }) {
            return true
        }
        return false
    }

    private func matches(_ predicate: StatePredicate, observation: AgentObservation) -> Bool {
        if let text = predicate.visibleTextContains, !text.isEmpty {
            guard observation.visibleText.contains(where: { $0.localizedCaseInsensitiveContains(text) }) else {
                return false
            }
        }
        if let context = predicate.appContextContains, !context.isEmpty {
            guard observation.appContext?.localizedCaseInsensitiveContains(context) == true else {
                return false
            }
        }
        if let controlId = predicate.controlId, !controlId.isEmpty {
            guard observation.controls.contains(where: { $0.id == controlId }) else {
                return false
            }
        }
        return true
    }
}

public struct GoalVerifier: GoalVerifying {
    public init() {}

    public func verify(
        goal: String,
        observation: AgentObservation,
        history: [StepRunRecord]
    ) -> GoalVerificationResult {
        guard let last = history.last else {
            return GoalVerificationResult(isSatisfied: false, message: "No actions have been taken yet.")
        }

        switch last.step.action {
        case .answer:
            if last.execution.status == .completed {
                return GoalVerificationResult(isSatisfied: true, message: "Goal completed with an in-app answer.")
            }
        case .askUser:
            if last.execution.status == .completed {
                return GoalVerificationResult(isSatisfied: true, message: "Goal paused after asking the user for missing information.")
            }
        case .handoff:
            if last.execution.status == .completed {
                return GoalVerificationResult(isSatisfied: true, message: "iOS-side work finished by handing off to an allowed external mode.")
            }
        case .invokeAppIntent:
            if last.execution.status == .completed {
                return GoalVerificationResult(isSatisfied: true, message: "First-party App Intent completed inside PrivateAgent.")
            }
        default:
            break
        }

        if last.verification?.verified == true, history.count == 1 {
            return GoalVerificationResult(isSatisfied: true, message: "Single-step plan was ACTION_VERIFIED.")
        }

        _ = goal
        _ = observation
        return GoalVerificationResult(isSatisfied: false, message: "Goal is not yet verified against the latest observation.")
    }
}
