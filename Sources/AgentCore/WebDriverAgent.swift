import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct WebDriverAgentStatus: Sendable, Codable, Equatable {
    public var ready: Bool
    public var message: String
    public var sessionId: String?

    public init(ready: Bool, message: String, sessionId: String? = nil) {
        self.ready = ready
        self.message = message
        self.sessionId = sessionId
    }
}

public struct WebDriverAgentObservationRequest: Sendable, Codable, Equatable {
    public var sessionId: UUID
    public var goal: String
    public var requestedAt: Date

    public init(sessionId: UUID = UUID(), goal: String, requestedAt: Date = Date()) {
        self.sessionId = sessionId
        self.goal = goal
        self.requestedAt = requestedAt
    }
}

public struct WebDriverAgentActionRequest: Sendable, Codable, Equatable {
    public var sessionId: UUID
    public var action: AgentAction
    public var requiresUserApproval: Bool

    public init(sessionId: UUID, action: AgentAction, requiresUserApproval: Bool = true) {
        self.sessionId = sessionId
        self.action = action
        self.requiresUserApproval = requiresUserApproval
    }
}

public struct WebDriverAgentResponse: Sendable, Codable, Equatable {
    public var status: AgentStepStatus
    public var message: String
    public var observation: AgentObservation?
    public var wdaSessionId: String?

    public init(
        status: AgentStepStatus,
        message: String,
        observation: AgentObservation? = nil,
        wdaSessionId: String? = nil
    ) {
        self.status = status
        self.message = message
        self.observation = observation
        self.wdaSessionId = wdaSessionId
    }
}

public protocol WebDriverAgentClient: Sendable {
    func status() async throws -> WebDriverAgentStatus
    func requestObservation(_ request: WebDriverAgentObservationRequest) async throws -> WebDriverAgentResponse
    func executeAction(_ request: WebDriverAgentActionRequest) async throws -> WebDriverAgentResponse
}

public enum WebDriverAgentClientError: Error, Sendable, Equatable {
    case invalidResponse
    case notDeveloperMode
}

public struct LocalWebDriverAgentClient: WebDriverAgentClient {
    private let baseURL: URL
    private let token: String?
    private let urlSession: URLSession

    public init(baseURL: URL, token: String? = nil, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.urlSession = urlSession
    }

    public func status() async throws -> WebDriverAgentStatus {
        var request = URLRequest(url: baseURL.appending(path: "status"))
        applyAuthorization(to: &request)
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw WebDriverAgentClientError.invalidResponse
        }
        return try JSONDecoder().decode(WebDriverAgentStatus.self, from: data)
    }

    public func requestObservation(_ request: WebDriverAgentObservationRequest) async throws -> WebDriverAgentResponse {
        try await post(request, path: "observation")
    }

    public func executeAction(_ request: WebDriverAgentActionRequest) async throws -> WebDriverAgentResponse {
        try await post(request, path: "action")
    }

    private func post<Request: Encodable>(_ body: Request, path: String) async throws -> WebDriverAgentResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthorization(to: &request)
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw WebDriverAgentClientError.invalidResponse
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WebDriverAgentResponse.self, from: data)
    }

    private func applyAuthorization(to request: inout URLRequest) {
        guard let token, !token.isEmpty else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
}

public struct WebDriverAgentActionExecutor: AgentActionExecuting {
    private let client: any WebDriverAgentClient
    private let sessionId: UUID
    private let requiresUserApproval: Bool

    public init(client: any WebDriverAgentClient, sessionId: UUID = UUID(), requiresUserApproval: Bool = true) {
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
            return ActionExecutionResult(action: action, status: .skipped, message: "WebDriverAgent does not handle this action.")
        }

        if case .handoff(let handoff) = action, handoff.target != .webDriverAgent {
            return ActionExecutionResult(action: action, status: .skipped, message: "Handoff target is not WebDriverAgent.")
        }

        let response = try await client.executeAction(
            WebDriverAgentActionRequest(
                sessionId: sessionId,
                action: action,
                requiresUserApproval: requiresUserApproval
            )
        )
        return ActionExecutionResult(action: action, status: response.status, message: response.message)
    }
}

public struct WebDriverAgentObserver: AgentObserving {
    private let client: any WebDriverAgentClient
    private let fallback: InAppObserver

    public init(client: any WebDriverAgentClient, fallback: InAppObserver = InAppObserver()) {
        self.client = client
        self.fallback = fallback
    }

    public func observe(goal: String, context: AgentObservationContext) async throws -> AgentObservation {
        do {
            let response = try await client.requestObservation(WebDriverAgentObservationRequest(goal: goal))
            if let observation = response.observation {
                return observation
            }
        } catch {
            // Developer-device only. Fall back to the in-app workspace.
        }
        return try await fallback.observe(goal: goal, context: context)
    }
}
