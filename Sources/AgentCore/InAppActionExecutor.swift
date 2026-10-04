import Foundation

public struct InAppActionExecutor: AgentActionExecuting {
    public init() {}

    public func canExecute(_ action: AgentAction) -> Bool {
        switch action {
        case .answer, .askUser, .wait:
            return true
        case .tap(let controlId), .type(let controlId, _):
            return InAppWorkspace.control(id: controlId) != nil
        case .invokeAppIntent(let name):
            return FirstPartyAppIntents.resolve(name) != nil
        case .openURL, .runShortcut, .scroll, .handoff:
            return false
        }
    }

    public func execute(_ action: AgentAction) async throws -> ActionExecutionResult {
        switch action {
        case .wait(let seconds):
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            if nanoseconds > 0 {
                try await Task.sleep(nanoseconds: nanoseconds)
            }
            return ActionExecutionResult(action: action, status: .completed, message: "Wait completed.")
        case .answer(let text):
            return ActionExecutionResult(action: action, status: .completed, message: text)
        case .askUser(let question):
            return ActionExecutionResult(action: action, status: .completed, message: question)
        case .tap(let controlId):
            guard let control = InAppWorkspace.control(id: controlId) else {
                return ActionExecutionResult(action: action, status: .failed, message: "Unknown in-app control \(controlId).")
            }
            let screen = InAppWorkspace.screen(forControlId: controlId)
            let screenName = screen?.rawValue ?? "unknown"
            return ActionExecutionResult(
                action: action,
                status: .completed,
                message: "Activated in-app control \(control.label). screen=\(screenName)"
            )
        case .type(let controlId, let text):
            guard let control = InAppWorkspace.control(id: controlId) else {
                return ActionExecutionResult(action: action, status: .failed, message: "Unknown in-app field \(controlId).")
            }
            return ActionExecutionResult(
                action: action,
                status: .completed,
                message: "Typed into \(control.label): \(text)"
            )
        case .invokeAppIntent(let name):
            guard let intent = FirstPartyAppIntents.resolve(name) else {
                return ActionExecutionResult(action: action, status: .skipped, message: "Unknown first-party App Intent.")
            }
            let screen = intent.screen.map { " screen=\($0.rawValue)" } ?? ""
            return ActionExecutionResult(
                action: action,
                status: .completed,
                message: "Invoked first-party App Intent \(intent.name).\(screen)"
            )
        case .openURL, .runShortcut, .scroll, .handoff:
            return ActionExecutionResult(action: action, status: .skipped, message: "In-app executor does not handle this action.")
        }
    }
}

public struct AppIntentActionExecutor: AgentActionExecuting {
    private let fallback: InAppActionExecutor

    public init() {
        self.fallback = InAppActionExecutor()
    }

    public func canExecute(_ action: AgentAction) -> Bool {
        if case .invokeAppIntent(let name) = action {
            return FirstPartyAppIntents.resolve(name) != nil
        }
        return false
    }

    public func execute(_ action: AgentAction) async throws -> ActionExecutionResult {
        guard canExecute(action) else {
            return ActionExecutionResult(action: action, status: .skipped, message: "No first-party App Intent is registered for this action.")
        }
        return try await fallback.execute(action)
    }
}
