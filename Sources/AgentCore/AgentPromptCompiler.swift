import Foundation

public struct AgentPromptCompiler: Sendable {
    public init() {}

    public func compilePrompt(observation: AgentObservation, allowedModes: [AutomationMode]) -> String {
        let modeText = allowedModes.map(\.rawValue).joined(separator: ", ")
        let visibleText = observation.visibleText.isEmpty ? "None" : observation.visibleText.joined(separator: "\n")
        let controls = observation.controls.map { control in
            "- \(control.id): \(control.role.rawValue) \(control.label) enabled=\(control.isEnabled)"
        }.joined(separator: "\n")

        return """
        You are PrivateAgent's iOS automation planner.

        Goal:
        \(observation.userGoal)

        Observation source: \(observation.source.rawValue)
        Allowed automation modes: \(modeText)
        App context: \(observation.appContext ?? "None")

        Visible text:
        \(visibleText)

        Controls:
        \(controls.isEmpty ? "None" : controls)

        Rules:
        - Prefer in-app actions when possible.
        - Do not claim normal iOS can inspect or control arbitrary third-party apps.
        - Use App Intents or Shortcuts only for explicit user-approved integrations.
        - Use Mac-assisted or WebDriverAgent handoff when the task requires cross-app screen reading or taps.
        - Require approval before destructive, privacy-sensitive, purchase, account, or external-control actions.
        - Return a concise JSON plan with summary, risk, requiresUserApproval, and steps.
        """
    }
}
