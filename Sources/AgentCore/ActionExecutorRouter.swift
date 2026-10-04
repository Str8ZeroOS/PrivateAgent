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
        guard let executor = executors.first(where: { $0.canExecute(action) }) else {
            return ActionExecutionResult(
                action: action,
                status: .skipped,
                message: "No executor is registered for this action."
            )
        }

        return try await executor.execute(action)
    }
}
