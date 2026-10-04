import Foundation
import AgentCore
import FlashMoEBridge

public enum PrivateAgentEngineTextGeneratorError: LocalizedError, Sendable {
    case modelNotReady

    public var errorDescription: String? {
        switch self {
        case .modelNotReady:
            return "Load a model before using local Agent Mode planning."
        }
    }
}

public struct PrivateAgentEngineTextGenerator: AgentTextGenerating {
    private let engine: PrivateAgentEngine
    private let config: GenerationConfig

    @MainActor
    public init(
        engine: PrivateAgentEngine,
        config: GenerationConfig = GenerationConfig(maxTokens: 900, temperature: 0.1, topP: 0.9, thinkBudget: 0)
    ) {
        self.engine = engine
        self.config = config
    }

    @MainActor
    public func generateText(prompt: String) async throws -> String {
        guard engine.state == .ready else {
            throw PrivateAgentEngineTextGeneratorError.modelNotReady
        }

        engine.resetConversation()
        var text = ""
        let stream = engine.generate(.formattedPrompt(prompt), config: config)

        for try await event in stream {
            switch event {
            case .token(let token, _):
                text += token
            case .finished, .prefillProgress, .thinkingStart, .thinkingEnd, .contextExhausted, .throttled:
                break
            }
        }

        return text
    }
}
