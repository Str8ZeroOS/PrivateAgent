import Foundation

public protocol AgentPlanning: Sendable {
    func makePlan(for observation: AgentObservation, allowedModes: [AutomationMode]) async throws -> AgentPlan
}

public struct RuleBasedAgentPlanner: AgentPlanning {
    public init() {}

    public func makePlan(for observation: AgentObservation, allowedModes: [AutomationMode]) async throws -> AgentPlan {
        let trimmedGoal = observation.userGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else {
            return AgentPlan(
                summary: "Ask for a task before acting.",
                steps: [
                    AgentStep(
                        action: .askUser("What would you like PrivateAgent to do?"),
                        rationale: "The agent needs a concrete goal.",
                        target: "user",
                        expectedResult: "User provides a goal"
                    )
                ],
                requiresUserApproval: false,
                risk: .low
            )
        }

        if requiresExternalAutomation(observation: observation) {
            let target = bestExternalMode(from: allowedModes)
            return AgentPlan(
                summary: "Prepare an external automation handoff.",
                steps: [
                    AgentStep(
                        action: .handoff(AgentHandoff(target: target, reason: "This task appears to require reading or controlling another app.")),
                        rationale: "Normal iOS apps cannot inspect and control arbitrary third-party apps like Android Accessibility Services.",
                        target: target.rawValue,
                        risk: target == .jailbreak ? .high : .medium,
                        requiresApproval: true,
                        expectedResult: "External automation mode accepted the handoff"
                    )
                ],
                requiresUserApproval: true,
                risk: target == .jailbreak ? .high : .medium
            )
        }

        return AgentPlan(
            summary: "Handle the request inside PrivateAgent.",
            steps: [
                AgentStep(
                    action: .answer(trimmedGoal),
                    rationale: "The task can be handled by the local chat/model workspace without external app control.",
                    target: "privateAgent",
                    expectedResult: trimmedGoal
                )
            ],
            requiresUserApproval: false,
            risk: .low
        )
    }

    private func requiresExternalAutomation(observation: AgentObservation) -> Bool {
        switch observation.source {
        case .macBridge, .webDriverAgent, .jailbreakBridge:
            return true
        case .privateAgentApp, .appIntent, .shortcuts, .userProvided:
            break
        }

        let goal = observation.userGoal.lowercased()
        let externalSignals = [
            "tap", "swipe", "scroll", "open app", "settings", "instagram", "youtube", "telegram", "chrome", "safari", "control my phone", "use my phone"
        ]
        return externalSignals.contains { goal.contains($0) }
    }

    private func bestExternalMode(from allowedModes: [AutomationMode]) -> AutomationMode {
        if allowedModes.contains(.macAssisted) { return .macAssisted }
        if allowedModes.contains(.webDriverAgent) { return .webDriverAgent }
        if allowedModes.contains(.shortcuts) { return .shortcuts }
        if allowedModes.contains(.appIntents) { return .appIntents }
        if allowedModes.contains(.jailbreak) { return .jailbreak }
        return .inApp
    }
}
