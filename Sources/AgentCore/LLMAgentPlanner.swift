import Foundation

public protocol AgentTextGenerating: Sendable {
    func generateText(prompt: String) async throws -> String
}

public struct LLMAgentPlanner<Generator: AgentTextGenerating>: AgentPlanning {
    private let generator: Generator
    private let promptCompiler: AgentPromptCompiler
    private let decoder: AgentPlanDecoding

    public init(
        generator: Generator,
        promptCompiler: AgentPromptCompiler = AgentPromptCompiler(),
        decoder: AgentPlanDecoding = JSONAgentPlanDecoder()
    ) {
        self.generator = generator
        self.promptCompiler = promptCompiler
        self.decoder = decoder
    }

    public func makePlan(for observation: AgentObservation, allowedModes: [AutomationMode]) async throws -> AgentPlan {
        let prompt = promptCompiler.compilePrompt(observation: observation, allowedModes: allowedModes)
        let response = try await generator.generateText(prompt: prompt)
        return try decoder.decodePlan(from: response)
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
