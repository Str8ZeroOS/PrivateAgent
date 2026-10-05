import Foundation

public struct InAppActionExecutor: AgentActionExecuting {
    private let navigator: any InAppNavigating

    public init(navigator: any InAppNavigating) {
        self.navigator = navigator
    }

    public init() {
        self.navigator = InAppWorkspaceStore()
    }

    public func canExecute(_ action: AgentAction) -> Bool {
        switch action {
        case .answer, .askUser, .wait:
            return true
        case .tap(let controlId), .type(let controlId, _):
            return InAppWorkspace.control(id: controlId) != nil
        case .invokeAppIntent(let name):
            return FirstPartyAppIntents.resolve(name) != nil
        case .openURL(let raw):
            return InAppDeepLink.screen(from: raw) != nil
        case .runShortcut, .scroll, .handoff:
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
            let result = await navigator.perform(.tap(controlId: controlId))
            return ActionExecutionResult(
                action: action,
                status: result.succeeded ? .completed : .failed,
                message: result.message
            )
        case .type(let controlId, let text):
            let result = await navigator.perform(.type(controlId: controlId, text: text))
            return ActionExecutionResult(
                action: action,
                status: result.succeeded ? .completed : .failed,
                message: result.message
            )
        case .invokeAppIntent(let name):
            let result = await navigator.perform(.invokeIntent(name))
            return ActionExecutionResult(
                action: action,
                status: result.succeeded ? .completed : .skipped,
                message: result.message
            )
        case .openURL(let raw):
            guard let screen = InAppDeepLink.screen(from: raw) else {
                return ActionExecutionResult(action: action, status: .skipped, message: "In-app executor does not handle this action.")
            }
            let result = await navigator.perform(.open(screen))
            return ActionExecutionResult(
                action: action,
                status: result.succeeded ? .completed : .failed,
                message: "Opened PrivateAgent deep link \(raw). \(result.message)"
            )
        case .runShortcut, .scroll, .handoff:
            return ActionExecutionResult(action: action, status: .skipped, message: "In-app executor does not handle this action.")
        }
    }
}

public struct AppIntentActionExecutor: AgentActionExecuting {
    private let fallback: InAppActionExecutor

    public init(navigator: any InAppNavigating) {
        self.fallback = InAppActionExecutor(navigator: navigator)
    }

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
