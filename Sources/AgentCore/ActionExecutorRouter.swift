import Foundation

public struct ActionExecutorRouter: AgentActionExecuting {
    private let executors: [any AgentActionExecuting]

    public init(executors: [any AgentActionExecuting]) {
        self.executors = executors
    }

    public func canExecute(_ action: AgentAction) -> Bool {
        executors.contains { $0.canExecute(action) }
    }

    public func execute(_ action: AgentAction) async throws -> ActionExecutionResult {
        let capable = executors.filter { $0.canExecute(action) }
        guard !capable.isEmpty else {
            return ActionExecutionResult(
                action: action,
                status: .skipped,
                message: "No executor is registered for this action."
            )
        }

        var lastResult: ActionExecutionResult?
        for executor in capable {
            let result = try await executor.execute(action)
            if result.status == .completed {
                return result
            }
            lastResult = result
            if result.status == .skipped || Self.looksUnavailable(result) {
                continue
            }
            return result
        }

        return lastResult ?? ActionExecutionResult(
            action: action,
            status: .skipped,
            message: "No executor is registered for this action."
        )
    }

    public func executeWithFallback(
        _ action: AgentAction,
        allowedModes: [AutomationMode]
    ) async throws -> ActionExecutionResult {
        let primary = try await execute(action)
        if primary.status == .completed {
            return primary
        }
        if primary.status == .failed && !Self.looksUnavailable(primary) {
            return primary
        }

        for alternate in CapabilityFallback.alternateActions(for: action, allowedModes: allowedModes) {
            let alternateResult = try await execute(alternate)
            if alternateResult.status == .completed {
                return ActionExecutionResult(
                    action: alternate,
                    status: .completed,
                    message: "Fallback succeeded: \(alternateResult.message)"
                )
            }
        }

        return primary
    }

    private static func looksUnavailable(_ result: ActionExecutionResult) -> Bool {
        let message = result.message.lowercased()
        return result.status == .skipped
            || message.contains("unavailable")
            || message.contains("not registered")
            || message.contains("no executor")
            || message.contains("unsupported")
    }
}
