import Foundation
import Observation
import AgentCore

@MainActor
@Observable
public final class AgentModeViewModel {
    public private(set) var goal: String = ""
    public private(set) var plan: AgentPlan?
    public private(set) var errorMessage: String?
    public var allowedModes: [AutomationMode] = [.inApp, .appIntents, .shortcuts]

    private let session: AgentSession

    public init(session: AgentSession = AgentSession()) {
        self.session = session
    }

    public func updateGoal(_ goal: String) {
        self.goal = goal
    }

    public func makePlan(visibleText: [String] = [], controls: [AgentControl] = [], appContext: String? = nil) async {
        errorMessage = nil
        await session.updateAllowedModes(allowedModes)

        let observation = AgentObservation(
            source: .privateAgentApp,
            userGoal: goal,
            visibleText: visibleText,
            controls: controls,
            appContext: appContext
        )

        do {
            plan = try await session.plan(for: observation)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
