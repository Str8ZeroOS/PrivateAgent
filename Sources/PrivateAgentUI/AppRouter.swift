import Foundation
import Observation
import AgentCore

/// A pairing code that arrived via a `privateagent://pair?...&code=` link and
/// is waiting for Agent Mode to send it to the bridge.
public struct PendingBridgePairing: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var code: String

    public init(host: String, port: Int, code: String) {
        self.host = host
        self.port = port
        self.code = code
    }
}

@MainActor
@Observable
public final class AppRouter {
    public static let shared = AppRouter()

    public var isAgentModePresented = false
    public var isModelsPresented = false
    public var isSettingsPresented = false
    public var startChatRequested = false
    public var lastPairingHost: String?
    public var pendingBridgePairing: PendingBridgePairing?

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
        switch BridgePairingLink.parse(url) {
        case .code(let host, let port, let code):
            // Only host/port are persisted here; the one-time code is handed to
            // Agent Mode, which exchanges it for a Keychain-stored token.
            UserDefaults.standard.set(host, forKey: BridgePairingStore.hostKey)
            UserDefaults.standard.set(String(port), forKey: BridgePairingStore.portKey)
            pendingBridgePairing = PendingBridgePairing(host: host, port: port, code: code)
            lastPairingHost = host
            open(.agentMode)
            return
        case .token(let pairing):
            // Legacy link from an older bridge script; the token goes to the Keychain.
            BridgePairingStore.save(pairing)
            lastPairingHost = pairing.host
            open(.agentMode)
            return
        case nil:
            break
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
