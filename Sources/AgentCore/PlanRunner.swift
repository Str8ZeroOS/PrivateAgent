import Foundation

public actor PlanRunner {
    private let executor: any AgentActionExecuting

    public init(executor: any AgentActionExecuting = PlanningOnlyActionExecutor()) {
        self.executor = executor
    }

    public func run(_ plan: AgentPlan) async -> [ActionExecutionResult] {
        var results: [ActionExecutionResult] = []

        for step in plan.steps {
            do {
                let result = try await executor.execute(step.action)
                results.append(result)
                if result.status == .failed {
                    break
                }
            } catch {
                results.append(
                    ActionExecutionResult(
                        action: step.action,
                        status: .failed,
                        message: error.localizedDescription
                    )
                )
                break
            }
        }

        return results
    }
}
