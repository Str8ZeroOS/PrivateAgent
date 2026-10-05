import Foundation
import AgentCore

#if canImport(UIKit)
import UIKit

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

        guard let url = URL(string: rawURL) else {
            return ActionExecutionResult(action: action, status: .failed, message: "Invalid URL.")
        }

        let canOpen = await MainActor.run {
            UIApplication.shared.canOpenURL(url)
        }
        guard canOpen else {
            return ActionExecutionResult(action: action, status: .failed, message: "Unsupported URL.")
        }

        await MainActor.run {
            UIApplication.shared.open(url)
        }
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

        guard let url = components?.url else {
            return ActionExecutionResult(action: action, status: .failed, message: "Shortcut URL could not be created.")
        }

        let canOpen = await MainActor.run {
            UIApplication.shared.canOpenURL(url)
        }
        guard canOpen else {
            return ActionExecutionResult(action: action, status: .failed, message: "Shortcuts is unavailable.")
        }

        await MainActor.run {
            UIApplication.shared.open(url)
        }
        return ActionExecutionResult(action: action, status: .completed, message: "Requested shortcut: \(shortcutName)")
    }
}
#endif

public enum SystemActionExecutorFactory {
    public static func platformExecutors() -> [any AgentActionExecuting] {
        #if canImport(UIKit)
        return [URLActionExecutor(), ShortcutActionExecutor()]
        #else
        return []
        #endif
    }

    public static func makeDefaultExecutor(
        allowedModes: [AutomationMode] = [.inApp, .appIntents, .shortcuts],
        macClient: (any MacBridgeClient)? = nil,
        wdaClient: (any WebDriverAgentClient)? = nil
    ) -> any AgentActionExecuting {
        #if canImport(UIKit)
        let navigator: any InAppNavigating = AppRouterNavigator()
        #else
        let navigator: any InAppNavigating = InAppWorkspaceStore.shared
        #endif
        return CapabilityRuntime.make(
            allowedModes: allowedModes,
            navigator: navigator,
            workspace: .shared,
            macClient: macClient,
            wdaClient: wdaClient,
            extraExecutors: platformExecutors()
        ).executor
    }
}
