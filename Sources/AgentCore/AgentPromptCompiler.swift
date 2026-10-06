import Foundation

public struct AgentPromptCompiler: Sendable {
    private let systemPrompt: String
    private let answerStyleEnabled: Bool

    public init(systemPrompt: String = AgentSystemPrompt.balanced, answerStyleEnabled: Bool = true) {
        self.systemPrompt = systemPrompt
        self.answerStyleEnabled = answerStyleEnabled
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

        This may be one remaining sub-goal of a larger user request. Plan only this next unfinished sub-goal. The runtime will observe and verify, then plan the next sub-goal. Do not treat one verified action as finishing the whole original request.

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
              "status": "pending",
              "target": "optional target",
              "risk": "low",
              "requiresApproval": false,
              "expectedResult": "optional observable result",
              "verification": { "kind": "none" }
            }
          ],
          "requiresUserApproval": false,
          "risk": "low"
        }

        Verification kinds: none, url_contains, visible_text_contains, control_exists, app_context_contains, state_predicate.
        Prefer one next action. After that action the runtime will observe and verify before planning again.
        Use answer only when the user asked to reply/say a specific phrase; the answer text must be exactly that phrase.\(answerStyleEnabled ? "\n" + AssistantStyleGuide.agentActionTextPrompt : "")
        Never mark a third-party app task (Apple Notes, Instagram, Safari, and similar) complete by echoing the goal. If iOS cannot drive that app from inside Str8ZeRO and there is no live Mac/WDA observation, ask the user or hand off instead of inventing success.

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
