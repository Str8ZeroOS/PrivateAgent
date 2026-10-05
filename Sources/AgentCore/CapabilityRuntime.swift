import Foundation

/// Builds the observer and executor the closed loop should actually use
/// for the current allowed modes and available adapters.
public struct CapabilityRuntime: Sendable {
    public var observer: any AgentObserving
    public var executor: any AgentActionExecuting

    public init(observer: any AgentObserving, executor: any AgentActionExecuting) {
        self.observer = observer
        self.executor = executor
    }

    public static func make(
        allowedModes: [AutomationMode],
        navigator: any InAppNavigating,
        workspace: InAppWorkspaceStore = .shared,
        macClient: (any MacBridgeClient)? = nil,
        wdaClient: (any WebDriverAgentClient)? = nil,
        extraExecutors: [any AgentActionExecuting] = []
    ) -> CapabilityRuntime {
        var executors: [any AgentActionExecuting] = [
            InAppActionExecutor(navigator: navigator),
            AppIntentActionExecutor(navigator: navigator)
        ]
        executors.append(contentsOf: extraExecutors)
        if allowedModes.contains(.macAssisted), let macClient {
            executors.append(MacBridgeActionExecutor(client: macClient))
        }
        if allowedModes.contains(.webDriverAgent), let wdaClient {
            executors.append(WebDriverAgentActionExecutor(client: wdaClient))
        }
        executors.append(PlanningOnlyActionExecutor())

        return CapabilityRuntime(
            observer: CapabilityObserver(
                allowedModes: allowedModes,
                workspace: workspace,
                macClient: macClient,
                wdaClient: wdaClient
            ),
            executor: ActionExecutorRouter(executors: executors)
        )
    }
}

/// Prefer a live WDA or Mac observation when those modes are allowed and
/// a client is configured. Fall back to the first-party workspace store.
public struct CapabilityObserver: AgentObserving {
    private let allowedModes: [AutomationMode]
    private let workspace: InAppWorkspaceStore
    private let macClient: (any MacBridgeClient)?
    private let wdaClient: (any WebDriverAgentClient)?

    public init(
        allowedModes: [AutomationMode],
        workspace: InAppWorkspaceStore = .shared,
        macClient: (any MacBridgeClient)? = nil,
        wdaClient: (any WebDriverAgentClient)? = nil
    ) {
        self.allowedModes = allowedModes
        self.workspace = workspace
        self.macClient = macClient
        self.wdaClient = wdaClient
    }

    public func observe(goal: String, context: AgentObservationContext) async throws -> AgentObservation {
        if allowedModes.contains(.webDriverAgent), let wdaClient {
            do {
                let response = try await wdaClient.requestObservation(WebDriverAgentObservationRequest(goal: goal))
                if let observation = response.observation {
                    return merge(observation, context: context)
                }
            } catch {
                // Developer-device adapter is optional.
            }
        }

        if allowedModes.contains(.macAssisted), let macClient {
            do {
                let response = try await macClient.requestObservation(MacBridgeObservationRequest(goal: goal))
                if let observation = response.observation {
                    return merge(observation, context: context)
                }
            } catch {
                // Mac bridge is optional.
            }
        }

        return try await LiveWorkspaceObserver(store: workspace).observe(goal: goal, context: context)
    }

    private func merge(_ observation: AgentObservation, context: AgentObservationContext) -> AgentObservation {
        var observation = observation
        if let result = context.lastResult, !observation.visibleText.contains(result.message) {
            observation.visibleText.append(result.message)
        }
        return observation
    }
}

public enum ExternalGoalURL {
    public static func inferred(from goal: String) -> String? {
        if let screen = InAppDeepLink.screen(inGoal: goal) {
            return InAppDeepLink.url(for: screen).absoluteString
        }

        for token in goal.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init) {
            guard let url = URL(string: token), let scheme = url.scheme?.lowercased() else { continue }
            if ["http", "https", "privateagent"].contains(scheme) {
                return token
            }
        }

        let lowered = goal.lowercased()
        if lowered.contains("youtube") {
            return "https://www.youtube.com"
        }
        if lowered.contains("instagram") {
            return "https://www.instagram.com"
        }
        return nil
    }
}
