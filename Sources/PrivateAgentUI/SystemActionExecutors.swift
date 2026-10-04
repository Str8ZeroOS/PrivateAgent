import Foundation
import UIKit
import AgentCore

public struct URLActionExecutor: AgentActionExecuting {
    public init() {}

    public func canExecute(_ action: AgentAction) -> Bool {
        if case .openURL = action { return true }
        return false
    }

    public func execute(_ action: AgentAction) async throws -> ActionExecutionResult {
        guard case .openURL(let rawURL) = action else {
            return ActionExecutionResult(action: action, status: .skipped, message: "Unsupported action.")
        }

        guard let url = URL(string: rawURL), await UIApplication.shared.canOpenURL(url) else {
            return ActionExecutionResult(action: action, status: .failed, message: "Invalid or unsupported URL.")
        }

        await UIApplication.shared.open(url)
        return ActionExecutionResult(action: action, status: .completed, message: "Opened URL.")
    }
}

public struct ShortcutActionExecutor: AgentActionExecuting {
    public init() {}

    public func canExecute(_ action: AgentAction) -> Bool {
        if case .runShortcut = action { return true }
        return false
    }

    public func execute(_ action: AgentAction) async throws -> ActionExecutionResult {
        guard case .runShortcut(let shortcutName) = action else {
            return ActionExecutionResult(action: action, status: .skipped, message: "Unsupported action.")
        }

        var components = URLComponents(string: "shortcuts://run-shortcut")
        components?.queryItems = [URLQueryItem(name: "name", value: shortcutName)]

        guard let url = components?.url, await UIApplication.shared.canOpenURL(url) else {
            return ActionExecutionResult(action: action, status: .failed, message: "Shortcuts is unavailable or the shortcut URL could not be created.")
        }

        await UIApplication.shared.open(url)
        return ActionExecutionResult(action: action, status: .completed, message: "Requested shortcut: \(shortcutName)")
    }
}
