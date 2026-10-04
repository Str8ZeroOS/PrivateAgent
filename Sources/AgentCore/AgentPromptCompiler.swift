import Foundation

public struct AgentPromptCompiler: Sendable {
    private let systemPrompt: String

    public init(systemPrompt: String = AgentSystemPrompt.balanced) {
        self.systemPrompt = systemPrompt
    }

    public func compilePrompt(observation: AgentObservation, allowedModes: [AutomationMode]) -> String {
        let modeText = allowedModes.map(\.rawValue).joined(separator: ", ")
        let visibleText = observation.visibleText.isEmpty ? "None" : observation.visibleText.joined(separator: "\n")
        let controls = observation.controls.map { control in
            "- \(control.id): \(control.role.rawValue) \(control.label) enabled=\(control.isEnabled)"
        }.joined(separator: "\n")

        return """
        SYSTEM PROMPT:
        \(systemPrompt)

        CURRENT TASK:
        Goal:
        \(observation.userGoal)

        Observation source: \(observation.source.rawValue)
        Allowed automation modes: \(modeText)
        App context: \(observation.appContext ?? "None")

        Visible text:
        \(visibleText)

        Controls:
        \(controls.isEmpty ? "None" : controls)

        Required JSON schema:
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

        Final reminder: return only valid JSON. Do not wrap it in Markdown.
        """
    }
}
