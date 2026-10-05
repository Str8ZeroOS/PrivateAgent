import Foundation
import Observation
import AgentCore

@MainActor
@Observable
public final class AppRouter {
    public static let shared = AppRouter()

    public var isAgentModePresented = false
    public var isModelsPresented = false
    public var isSettingsPresented = false
    public var startChatRequested = false
    public var lastPairingHost: String?

    public init() {}

    public func present(_ screen: InAppScreen) {
        switch screen {
        case .agentMode:
            isAgentModePresented = true
        case .models:
            isModelsPresented = true
        case .settings:
            isSettingsPresented = true
        case .chat:
            startChatRequested = true
        case .chats:
            isModelsPresented = false
            isSettingsPresented = false
        }
    }

    public func open(_ screen: InAppScreen) {
        present(screen)
        Task {
            _ = await InAppWorkspaceStore.shared.perform(.open(screen))
        }
    }

    public func open(url: URL) {
        if let pairing = BridgePairing.fromDeepLink(url) {
            BridgePairingStore.save(pairing)
            lastPairingHost = pairing.host
            open(.agentMode)
            return
        }
        guard let screen = InAppDeepLink.screen(from: url) else { return }
        open(screen)
    }
}

public struct AppRouterNavigator: InAppNavigating {
    public init() {}

    public func perform(_ command: InAppNavigationCommand) async -> InAppNavigationResult {
        let result = await InAppWorkspaceStore.shared.perform(command)
        await AppRouter.shared.present(result.screen)
        return result
    }
}
