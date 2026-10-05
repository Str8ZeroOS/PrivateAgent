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
        let workspace = InAppWorkspace.observation(goal: goal)
        var text = context.visibleText.isEmpty ? (visibleText.isEmpty ? workspace.visibleText : visibleText) : context.visibleText
        if let result = context.lastResult {
            text.append(result.message)
        }
        var controls = context.controls.isEmpty
            ? (self.controls.isEmpty ? workspace.controls : self.controls)
            : context.controls
        var appContext = context.appContext ?? self.appContext ?? workspace.appContext
        if let screen = inferredScreen(from: context.lastResult?.message) {
            appContext = InAppWorkspace.appContext(for: screen)
            controls = InAppWorkspace.controls(on: screen)
            text.append(contentsOf: InAppWorkspace.visibleText(on: screen))
        }
        return AgentObservation(
            source: context.source,
            userGoal: goal,
            visibleText: text,
            controls: controls,
            appContext: appContext
        )
    }

    private func inferredScreen(from message: String?) -> InAppScreen? {
        guard let message else { return nil }
        for screen in InAppScreen.allCases {
            if message.contains("screen=\(screen.rawValue)") {
                return screen
            }
        }
        return nil
    }
}

public struct MacBridgeObserver: AgentObserving {
    private let client: any MacBridgeClient
    private let fallback: InAppObserver

    public init(client: any MacBridgeClient, fallback: InAppObserver = InAppObserver()) {
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
