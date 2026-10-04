import Foundation

public struct AgentObservationContext: Sendable, Equatable {
    public var previous: AgentObservation?
    public var lastAction: AgentAction?
    public var lastResult: ActionExecutionResult?
    public var visibleText: [String]
    public var controls: [AgentControl]
    public var appContext: String?
    public var source: ObservationSource

    public init(
        previous: AgentObservation? = nil,
        lastAction: AgentAction? = nil,
        lastResult: ActionExecutionResult? = nil,
        visibleText: [String] = [],
        controls: [AgentControl] = [],
        appContext: String? = nil,
        source: ObservationSource = .privateAgentApp
    ) {
        self.previous = previous
        self.lastAction = lastAction
        self.lastResult = lastResult
        self.visibleText = visibleText
        self.controls = controls
        self.appContext = appContext
        self.source = source
    }
}

public protocol AgentObserving: Sendable {
    func observe(goal: String, context: AgentObservationContext) async throws -> AgentObservation
}

public struct InAppObserver: AgentObserving {
    public var visibleText: [String]
    public var controls: [AgentControl]
    public var appContext: String?
    public var source: ObservationSource

    public init(
        visibleText: [String] = [],
        controls: [AgentControl] = [],
        appContext: String? = nil,
        source: ObservationSource = .privateAgentApp
    ) {
        self.visibleText = visibleText
        self.controls = controls
        self.appContext = appContext
        self.source = source
    }

    public func observe(goal: String, context: AgentObservationContext) async throws -> AgentObservation {
        var text = context.visibleText.isEmpty ? visibleText : context.visibleText
        if let result = context.lastResult {
            text.append(result.message)
        }
        let controls = context.controls.isEmpty ? self.controls : context.controls
        let appContext = context.appContext ?? self.appContext
        return AgentObservation(
            source: context.source,
            userGoal: goal,
            visibleText: text,
            controls: controls,
            appContext: appContext
        )
    }
}

public struct MacBridgeObserver<Client: MacBridgeClient>: AgentObserving {
    private let client: Client
    private let fallback: InAppObserver

    public init(client: Client, fallback: InAppObserver = InAppObserver()) {
        self.client = client
        self.fallback = fallback
    }

    public func observe(goal: String, context: AgentObservationContext) async throws -> AgentObservation {
        do {
            let response = try await client.requestObservation(MacBridgeObservationRequest(goal: goal))
            if let observation = response.observation {
                return observation
            }
        } catch {
            // Honest iOS fallback: the Mac bridge is optional.
        }
        return try await fallback.observe(goal: goal, context: context)
    }
}
