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
        You are PrivateAgent's iOS automation planner. Return only JSON. Do not wrap it in Markdown.

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
        - Use risk values only: "low", "medium", "high".
        - Use step status value "pending" for every new step.
        - Use a fresh UUID string for each step id.

        Output schema:
        {
          "summary": "short plan summary",
          "steps": [
            {
              "id": "UUID-string",
              "action": { "answer": { "_0": "text to show" } },
              "rationale": "why this step is needed",
              "status": "pending"
            }
          ],
          "requiresUserApproval": false,
          "risk": "low"
        }

        Action encodings:
        - Answer: { "answer": { "_0": "text" } }
        - Ask user: { "askUser": { "_0": "question" } }
        - Open URL: { "openURL": { "_0": "https://example.com" } }
        - Run Shortcut: { "runShortcut": { "_0": "Shortcut Name" } }
        - Invoke App Intent: { "invokeAppIntent": { "_0": "Intent Name" } }
        - Tap: { "tap": { "controlId": "control-id" } }
        - Type: { "type": { "controlId": "control-id", "text": "text" } }
        - Scroll: { "scroll": { "direction": "down" } }
        - Wait: { "wait": { "seconds": 1.0 } }
        - Handoff: { "handoff": { "_0": { "target": "macAssisted", "reason": "why external control is needed" } } }
        """
    }
}
