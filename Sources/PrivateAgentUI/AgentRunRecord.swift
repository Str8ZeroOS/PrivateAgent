import Foundation
import SwiftData
import AgentCore

@Model
public final class AgentRunRecord {
    public var id: UUID
    public var createdAt: Date
    public var goal: String
    public var planningMode: String
    public var allowedModesJSON: String
    public var observationJSON: String
    public var planJSON: String?
    public var diagnosticsJSON: String?
    public var executionResultsJSON: String?
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        goal: String,
        planningMode: String,
        allowedModesJSON: String,
        observationJSON: String,
        planJSON: String? = nil,
        diagnosticsJSON: String? = nil,
        executionResultsJSON: String? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.goal = goal
        self.planningMode = planningMode
        self.allowedModesJSON = allowedModesJSON
        self.observationJSON = observationJSON
        self.planJSON = planJSON
        self.diagnosticsJSON = diagnosticsJSON
        self.executionResultsJSON = executionResultsJSON
        self.errorMessage = errorMessage
    }
}

public enum AgentRunRecordCoding {
    public static func encode<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
