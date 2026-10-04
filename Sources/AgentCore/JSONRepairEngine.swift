import Foundation

public enum AgentPlanDecodingError: Error, Sendable, LocalizedError, Equatable {
    case noJSONFound
    case schemaViolation(String)

    public var errorDescription: String? {
        switch self {
        case .noJSONFound:
            return "Model output did not contain a JSON object."
        case .schemaViolation(let message):
            return message
        }
    }
}

public struct JSONRepairOutcome<Value: Sendable>: Sendable {
    public var value: Value
    public var rawJSON: String
    public var diagnostics: AgentPlannerDiagnostics

    public init(value: Value, rawJSON: String, diagnostics: AgentPlannerDiagnostics) {
        self.value = value
        self.rawJSON = rawJSON
        self.diagnostics = diagnostics
    }
}

public struct JSONRepairEngine: Sendable {
    public init() {}

    public static func extractJSONObject(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fenceStart = trimmed.range(of: "```json") ?? trimmed.range(of: "```") {
            let afterFence = trimmed[fenceStart.upperBound...]
            if let fenceEnd = afterFence.range(of: "```") {
                let fenced = String(afterFence[..<fenceEnd.lowerBound])
                if let object = firstJSONObject(in: fenced) {
                    return object
                }
            }
        }
        return firstJSONObject(in: trimmed) ?? trimmed
    }

    public static func describeSchemaViolation(_ error: Error) -> String {
        switch error {
        case let decoding as DecodingError:
            return describeDecodingError(decoding)
        case let planError as AgentPlanDecodingError:
            return planError.localizedDescription
        default:
            return error.localizedDescription
        }
    }

    public func decodePlan(
        from raw: String,
        decoder: any AgentPlanDecoding = JSONAgentPlanDecoder(),
        generator: (any AgentTextGenerating)? = nil,
        repairPromptCompiler: AgentPlanRepairPromptCompiler = AgentPlanRepairPromptCompiler(),
        maxRepairAttempts: Int = AgentLoopLimits.default.maxJSONRepairAttempts
    ) async throws -> JSONRepairOutcome<AgentPlan> {
        var current = raw
        var lastError: Error?

        do {
            let plan = try decoder.decodePlan(from: current)
            return JSONRepairOutcome(
                value: plan,
                rawJSON: Self.extractJSONObject(from: current),
                diagnostics: AgentPlannerDiagnostics()
            )
        } catch {
            lastError = error
        }

        guard let generator, maxRepairAttempts > 0 else {
            throw lastError ?? AgentPlanDecodingError.schemaViolation("Plan JSON could not be decoded.")
        }

        for attempt in 1...maxRepairAttempts {
            let violation = Self.describeSchemaViolation(lastError ?? AgentPlanDecodingError.noJSONFound)
            let repairPrompt = repairPromptCompiler.compileRepairPrompt(
                malformedResponse: current,
                decodeError: AgentPlanDecodingError.schemaViolation(violation)
            )
            current = try await generator.generateText(prompt: repairPrompt)

            do {
                let plan = try decoder.decodePlan(from: current)
                return JSONRepairOutcome(
                    value: plan,
                    rawJSON: Self.extractJSONObject(from: current),
                    diagnostics: AgentPlannerDiagnostics(repairAttempts: attempt, usedRepair: true)
                )
            } catch {
                lastError = error
            }
        }

        throw lastError ?? AgentPlanDecodingError.schemaViolation("JSON repair attempts exhausted.")
    }

    private static func firstJSONObject(in text: String) -> String? {
        guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first <= last else {
            return nil
        }
        return String(text[first...last])
    }

    private static func describeDecodingError(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "Missing key '\(key.stringValue)' at \(path(context.codingPath))."
        case .typeMismatch(let type, let context):
            return "Type mismatch for \(type) at \(path(context.codingPath)): \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "Expected \(type) at \(path(context.codingPath)) but found null."
        case .dataCorrupted(let context):
            return "Corrupted JSON at \(path(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func path(_ codingPath: [CodingKey]) -> String {
        let parts = codingPath.map(\.stringValue)
        return parts.isEmpty ? "<root>" : parts.joined(separator: ".")
    }
}
