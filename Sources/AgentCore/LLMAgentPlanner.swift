import Foundation

public protocol AgentTextGenerating: Sendable {
    @MainActor
    func generateText(prompt: String) async throws -> String
}

public struct LLMAgentPlanner<Generator: AgentTextGenerating>: AgentPlanning {
    private let generator: Generator
    private let promptCompiler: AgentPromptCompiler
    private let repairPromptCompiler: AgentPlanRepairPromptCompiler
    private let decoder: any AgentPlanDecoding
    private let maxRepairAttempts: Int

    public init(
        generator: Generator,
        promptCompiler: AgentPromptCompiler = AgentPromptCompiler(),
        repairPromptCompiler: AgentPlanRepairPromptCompiler = AgentPlanRepairPromptCompiler(),
        decoder: any AgentPlanDecoding = JSONAgentPlanDecoder(),
        maxRepairAttempts: Int = 1
    ) {
        self.generator = generator
        self.promptCompiler = promptCompiler
        self.repairPromptCompiler = repairPromptCompiler
        self.decoder = decoder
        self.maxRepairAttempts = maxRepairAttempts
    }

    public func makePlan(for observation: AgentObservation, allowedModes: [AutomationMode]) async throws -> AgentPlan {
        let prompt = promptCompiler.compilePrompt(observation: observation, allowedModes: allowedModes)
        var response = try await generator.generateText(prompt: prompt)

        do {
            return try decoder.decodePlan(from: response)
        } catch {
            guard maxRepairAttempts > 0 else { throw error }
            var lastError: Error = error

            for _ in 0..<maxRepairAttempts {
                let repairPrompt = repairPromptCompiler.compileRepairPrompt(malformedResponse: response, decodeError: lastError)
                response = try await generator.generateText(prompt: repairPrompt)

                do {
                    return try decoder.decodePlan(from: response)
                } catch {
                    lastError = error
                }
            }

            throw lastError
        }
    }
}

public protocol AgentPlanDecoding: Sendable {
    func decodePlan(from text: String) throws -> AgentPlan
}

public struct JSONAgentPlanDecoder: AgentPlanDecoding {
    public init() {}

    public func decodePlan(from text: String) throws -> AgentPlan {
        let json = extractJSONObject(from: text)
        let data = Data(json.utf8)
        return try JSONDecoder().decode(AgentPlan.self, from: data)
    }

    private func extractJSONObject(from text: String) -> String {
        guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first <= last else {
            return text
        }

        return String(text[first...last])
    }
}

public struct AgentPlanRepairPromptCompiler: Sendable {
    public init() {}

    public func compileRepairPrompt(malformedResponse: String, decodeError: Error) -> String {
        """
        Repair this PrivateAgent plan response so it is valid JSON matching the required schema. Return only JSON. Do not include Markdown, comments, or explanation.

        Decode error:
        \(decodeError.localizedDescription)

        Malformed response:
        \(malformedResponse)

        Required schema:
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

        Valid action encodings:
        - { "answer": { "_0": "text" } }
        - { "askUser": { "_0": "question" } }
        - { "openURL": { "_0": "https://example.com" } }
        - { "runShortcut": { "_0": "Shortcut Name" } }
        - { "invokeAppIntent": { "_0": "Intent Name" } }
        - { "tap": { "controlId": "control-id" } }
        - { "type": { "controlId": "control-id", "text": "text" } }
        - { "scroll": { "direction": "down" } }
        - { "wait": { "seconds": 1.0 } }
        - { "handoff": { "_0": { "target": "macAssisted", "reason": "why external control is needed" } } }
        """
    }
}
