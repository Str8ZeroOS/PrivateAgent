import Foundation

public struct MacBridgeObservationRequest: Sendable, Codable, Equatable {
    public var sessionId: UUID
    public var goal: String
    public var requestedAt: Date

    public init(sessionId: UUID = UUID(), goal: String, requestedAt: Date = Date()) {
        self.sessionId = sessionId
        self.goal = goal
        self.requestedAt = requestedAt
    }
}

public struct MacBridgeActionRequest: Sendable, Codable, Equatable {
    public var sessionId: UUID
    public var action: AgentAction
    public var requiresUserApproval: Bool

    public init(sessionId: UUID, action: AgentAction, requiresUserApproval: Bool) {
        self.sessionId = sessionId
        self.action = action
        self.requiresUserApproval = requiresUserApproval
    }
}

public struct MacBridgeResponse: Sendable, Codable, Equatable {
    public var status: AgentStepStatus
    public var message: String
    public var observation: AgentObservation?

    public init(status: AgentStepStatus, message: String, observation: AgentObservation? = nil) {
        self.status = status
        self.message = message
        self.observation = observation
    }
}

public protocol MacBridgeClient: Sendable {
    func requestObservation(_ request: MacBridgeObservationRequest) async throws -> MacBridgeResponse
    func executeAction(_ request: MacBridgeActionRequest) async throws -> MacBridgeResponse
}

public struct MacBridgeActionExecutor<Client: MacBridgeClient>: AgentActionExecuting {
    private let client: Client
    private let sessionId: UUID
    private let requiresUserApproval: Bool

    public init(client: Client, sessionId: UUID = UUID(), requiresUserApproval: Bool = true) {
        self.client = client
        self.sessionId = sessionId
        self.requiresUserApproval = requiresUserApproval
    }

    public func canExecute(_ action: AgentAction) -> Bool {
        switch action {
        case .openURL, .tap, .type, .scroll, .wait, .handoff:
            return true
        case .answer, .askUser, .runShortcut, .invokeAppIntent:
            return false
        }
    }

    public func execute(_ action: AgentAction) async throws -> ActionExecutionResult {
        guard canExecute(action) else {
            return ActionExecutionResult(action: action, status: .skipped, message: "Mac bridge does not handle this action.")
        }

        let response = try await client.executeAction(
            MacBridgeActionRequest(
                sessionId: sessionId,
                action: action,
                requiresUserApproval: requiresUserApproval
            )
        )

        return ActionExecutionResult(action: action, status: response.status, message: response.message)
    }
}
