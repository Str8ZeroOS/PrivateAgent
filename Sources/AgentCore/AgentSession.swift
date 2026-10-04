import Foundation

public actor AgentSession {
    private let planner: AgentPlanning
    private var allowedModes: [AutomationMode]
    private var currentPlan: AgentPlan?

    public init(planner: AgentPlanning = RuleBasedAgentPlanner(), allowedModes: [AutomationMode] = [.inApp, .appIntents, .shortcuts]) {
        self.planner = planner
        self.allowedModes = allowedModes
    }

    public func updateAllowedModes(_ modes: [AutomationMode]) {
        allowedModes = modes
    }

    public func plan(for observation: AgentObservation) async throws -> AgentPlan {
        let plan = try await planner.makePlan(for: observation, allowedModes: allowedModes)
        currentPlan = plan
        return plan
    }

    public func lastPlan() -> AgentPlan? {
        currentPlan
    }
}
