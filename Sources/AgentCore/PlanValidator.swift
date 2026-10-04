import Foundation

public enum PlanValidationSeverity: String, Sendable, Codable, Equatable {
    case warning
    case error
}

public struct PlanValidationIssue: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var severity: PlanValidationSeverity
    public var message: String

    public init(id: UUID = UUID(), severity: PlanValidationSeverity, message: String) {
        self.id = id
        self.severity = severity
        self.message = message
    }
}

public struct PlanValidationResult: Sendable, Codable, Equatable {
    public var isValid: Bool
    public var issues: [PlanValidationIssue]
    public var requiresApproval: Bool

    public init(isValid: Bool, issues: [PlanValidationIssue], requiresApproval: Bool) {
        self.isValid = isValid
        self.issues = issues
        self.requiresApproval = requiresApproval
    }

    public var errorMessages: [String] {
        issues.filter { $0.severity == .error }.map(\.message)
    }
}

public protocol PlanValidating: Sendable {
    func validate(
        _ plan: AgentPlan,
        observation: AgentObservation,
        allowedModes: [AutomationMode],
        executor: any AgentActionExecuting
    ) -> PlanValidationResult
}

public struct PlanValidator: PlanValidating {
    public var policy: AgentPolicy

    public init(policy: AgentPolicy = .default) {
        self.policy = policy
    }

    public func validate(
        _ plan: AgentPlan,
        observation: AgentObservation,
        allowedModes: [AutomationMode],
        executor: any AgentActionExecuting
    ) -> PlanValidationResult {
        var issues: [PlanValidationIssue] = []
        var requiresApproval = plan.requiresUserApproval || plan.risk >= policy.requireApprovalAtOrAbove

        if plan.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(PlanValidationIssue(severity: .error, message: "Plan summary is empty."))
        }
        if plan.steps.isEmpty {
            issues.append(PlanValidationIssue(severity: .error, message: "Plan has no steps."))
        }

        for step in plan.steps {
            if step.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(PlanValidationIssue(severity: .warning, message: "Step \(step.id.uuidString) is missing a rationale."))
            }

            if step.requiresApproval || step.risk >= policy.requireApprovalAtOrAbove || step.risk == .high {
                requiresApproval = true
            }

            switch step.action {
            case .openURL(let raw):
                if !isPlausibleURL(raw) {
                    issues.append(PlanValidationIssue(severity: .error, message: "Invalid URL: \(raw)"))
                }
                requiresApproval = true
            case .tap(let controlId):
                if !observation.controls.isEmpty && !observation.controls.contains(where: { $0.id == controlId }) {
                    issues.append(PlanValidationIssue(severity: .warning, message: "Tap target \(controlId) is not in the current observation."))
                }
                if !hasExternalUIControl(allowedModes) {
                    issues.append(PlanValidationIssue(severity: .error, message: "Tap requires Mac-assisted, WebDriverAgent, or jailbreak capability."))
                }
                requiresApproval = true
            case .type(let controlId, let text):
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(PlanValidationIssue(severity: .error, message: "Type action has empty text."))
                }
                if !observation.controls.isEmpty && !observation.controls.contains(where: { $0.id == controlId }) {
                    issues.append(PlanValidationIssue(severity: .warning, message: "Type target \(controlId) is not in the current observation."))
                }
                if !hasExternalUIControl(allowedModes) {
                    issues.append(PlanValidationIssue(severity: .error, message: "Type requires Mac-assisted, WebDriverAgent, or jailbreak capability."))
                }
                requiresApproval = true
            case .scroll:
                if !hasExternalUIControl(allowedModes) {
                    issues.append(PlanValidationIssue(severity: .error, message: "Scroll requires an external-control capability."))
                }
                requiresApproval = true
            case .handoff(let handoff):
                if !allowedModes.contains(handoff.target) {
                    issues.append(PlanValidationIssue(severity: .error, message: "Handoff target \(handoff.target.rawValue) is not allowed."))
                }
                if handoff.target == .jailbreak && !policy.allowJailbreak {
                    issues.append(PlanValidationIssue(severity: .error, message: "Jailbreak handoff is blocked by policy."))
                }
                requiresApproval = true
            case .runShortcut, .invokeAppIntent:
                requiresApproval = true
            case .answer, .askUser, .wait:
                break
            }

            if !executor.canExecute(step.action) {
                let alternates = CapabilityFallback.alternateActions(for: step.action, allowedModes: allowedModes)
                if alternates.isEmpty {
                    issues.append(PlanValidationIssue(severity: .error, message: "No executor or capability fallback is available for this action."))
                } else {
                    issues.append(PlanValidationIssue(severity: .warning, message: "Primary executor is unavailable; a capability fallback exists."))
                }
            }
        }

        let isValid = !issues.contains(where: { $0.severity == .error })
        return PlanValidationResult(isValid: isValid, issues: issues, requiresApproval: requiresApproval)
    }

    private func hasExternalUIControl(_ allowedModes: [AutomationMode]) -> Bool {
        allowedModes.contains(.macAssisted) || allowedModes.contains(.webDriverAgent) || allowedModes.contains(.jailbreak)
    }

    private func isPlausibleURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw), url.scheme != nil else { return false }
        let scheme = url.scheme?.lowercased() ?? ""
        return ["http", "https", "shortcuts", "mailto", "tel", "sms"].contains(scheme)
    }
}
