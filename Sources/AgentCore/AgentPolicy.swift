import Foundation

public enum PolicyDecision: Sendable, Codable, Equatable {
    case allow
    case requireApproval(reason: String)
    case deny(reason: String)
}

public struct AgentPolicy: Sendable, Codable, Equatable {
    public var requireApprovalAtOrAbove: AgentRisk
    public var allowJailbreak: Bool
    public var autoApproveInAppAnswers: Bool

    public static let `default` = AgentPolicy(
        requireApprovalAtOrAbove: .high,
        allowJailbreak: false,
        autoApproveInAppAnswers: true
    )

    public init(
        requireApprovalAtOrAbove: AgentRisk = .high,
        allowJailbreak: Bool = false,
        autoApproveInAppAnswers: Bool = true
    ) {
        self.requireApprovalAtOrAbove = requireApprovalAtOrAbove
        self.allowJailbreak = allowJailbreak
        self.autoApproveInAppAnswers = autoApproveInAppAnswers
    }

    public func decision(for plan: AgentPlan, validation: PlanValidationResult) -> PolicyDecision {
        if !allowJailbreak && plan.steps.contains(where: isJailbreakHandoff) {
            return .deny(reason: "Jailbreak automation is disabled by policy.")
        }

        if autoApproveInAppAnswers && isInAppLowRisk(plan) && !validation.requiresApproval && !plan.requiresUserApproval {
            return .allow
        }

        if validation.requiresApproval || plan.requiresUserApproval || plan.risk >= requireApprovalAtOrAbove {
            return .requireApproval(reason: "This plan needs approval before execution.")
        }

        if let step = plan.steps.first(where: { $0.requiresApproval || $0.risk >= requireApprovalAtOrAbove }) {
            return .requireApproval(reason: "A step requires approval (\(step.risk.rawValue)).")
        }

        return .allow
    }

    private func isJailbreakHandoff(_ step: AgentStep) -> Bool {
        if case .handoff(let handoff) = step.action {
            return handoff.target == .jailbreak
        }
        return false
    }

    private func isInAppLowRisk(_ plan: AgentPlan) -> Bool {
        guard plan.risk == .low else { return false }
        return plan.steps.allSatisfy { step in
            switch step.action {
            case .answer, .askUser, .wait:
                return step.risk == .low && !step.requiresApproval
            default:
                return false
            }
        }
    }
}

public struct AgentApprovalRequest: Sendable, Codable, Equatable {
    public var plan: AgentPlan
    public var reason: String
    public var risk: AgentRisk

    public init(plan: AgentPlan, reason: String, risk: AgentRisk) {
        self.plan = plan
        self.reason = reason
        self.risk = risk
    }
}

public enum AgentApprovalDecision: String, Sendable, Codable, Equatable {
    case approved
    case rejected
    case cancelled
}

public protocol AgentApprovalHandling: Sendable {
    func decide(_ request: AgentApprovalRequest) async -> AgentApprovalDecision
}

public struct AutoApprovingHandler: AgentApprovalHandling {
    public init() {}

    public func decide(_ request: AgentApprovalRequest) async -> AgentApprovalDecision {
        _ = request
        return .approved
    }
}

public actor AgentApprovalBroker: AgentApprovalHandling {
    private var pending: CheckedContinuation<AgentApprovalDecision, Never>?
    public private(set) var currentRequest: AgentApprovalRequest?

    public init() {}

    public func decide(_ request: AgentApprovalRequest) async -> AgentApprovalDecision {
        currentRequest = request
        return await withCheckedContinuation { continuation in
            pending = continuation
        }
    }

    public func respond(_ decision: AgentApprovalDecision) {
        pending?.resume(returning: decision)
        pending = nil
        currentRequest = nil
    }
}
