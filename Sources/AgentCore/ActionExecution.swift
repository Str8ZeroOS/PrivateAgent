import Foundation

public struct ActionExecutionResult: Sendable, Codable, Equatable {
    public var action: AgentAction
    public var status: AgentStepStatus
    public var message: String

    public init(action: AgentAction, status: AgentStepStatus, message: String) {
        self.action = action
        self.status = status
        self.message = message
    }
}

public protocol AgentActionExecuting: Sendable {
    func canExecute(_ action: AgentAction) -> Bool
    func execute(_ action: AgentAction) async throws -> ActionExecutionResult
}

public struct PlanningOnlyActionExecutor: AgentActionExecuting {
    public init() {}

    public func canExecute(_ action: AgentAction) -> Bool {
        switch action {
        case .answer, .askUser, .handoff, .wait:
            return true
        case .openURL, .runShortcut, .invokeAppIntent, .tap, .type, .scroll:
            return false
        }
    }

    public func execute(_ action: AgentAction) async throws -> ActionExecutionResult {
        guard canExecute(action) else {
            return ActionExecutionResult(action: action, status: .skipped, message: "No executor is registered for this action yet.")
        }

        switch action {
        case .wait(let seconds):
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanoseconds)
            return ActionExecutionResult(action: action, status: .completed, message: "Wait completed.")
        case .answer(let text):
            return ActionExecutionResult(action: action, status: .completed, message: text)
        case .askUser(let question):
            return ActionExecutionResult(action: action, status: .completed, message: question)
        case .handoff(let handoff):
            return ActionExecutionResult(action: action, status: .completed, message: handoff.reason)
        case .openURL, .runShortcut, .invokeAppIntent, .tap, .type, .scroll:
            return ActionExecutionResult(action: action, status: .skipped, message: "No executor is registered for this action yet.")
        }
    }
}
