import Foundation

public enum InAppNavigationCommand: Sendable, Equatable {
    case tap(controlId: String)
    case type(controlId: String, text: String)
    case invokeIntent(String)
    case open(InAppScreen)
}

public struct InAppNavigationResult: Sendable, Equatable {
    public var didNavigate: Bool
    public var screen: InAppScreen
    public var message: String
    public var succeeded: Bool

    public init(didNavigate: Bool, screen: InAppScreen, message: String, succeeded: Bool = true) {
        self.didNavigate = didNavigate
        self.screen = screen
        self.message = message
        self.succeeded = succeeded
    }
}

public protocol InAppNavigating: Sendable {
    func perform(_ command: InAppNavigationCommand) async -> InAppNavigationResult
}

public actor InAppWorkspaceStore: InAppNavigating {
    public static let shared = InAppWorkspaceStore()

    private var screen: InAppScreen
    private var fieldValues: [String: String]
    private var extraVisibleText: [String]
    private var liveSnapshot: AccessibilitySnapshot?

    public init(screen: InAppScreen = .agentMode) {
        self.screen = screen
        self.fieldValues = [:]
        self.extraVisibleText = []
        self.liveSnapshot = nil
    }

    public func currentScreen() -> InAppScreen {
        screen
    }

    public func publish(_ snapshot: AccessibilitySnapshot) {
        screen = snapshot.screen
        liveSnapshot = snapshot
    }

    public func latestLiveSnapshot() -> AccessibilitySnapshot? {
        liveSnapshot
    }

    public func snapshot(goal: String) -> AgentObservation {
        let live = liveSnapshot.flatMap { $0.screen == screen ? $0 : nil }
        var text = AccessibilitySnapshotMerge.visibleText(
            catalog: InAppWorkspace.visibleText(on: screen),
            live: live
        )
        text.append(contentsOf: extraVisibleText)
        for key in fieldValues.keys.sorted() {
            if let value = fieldValues[key], !value.isEmpty {
                text.append("\(key)=\(value)")
            }
        }
        return AgentObservation(
            source: .privateAgentApp,
            userGoal: goal,
            visibleText: text,
            controls: AccessibilitySnapshotMerge.controls(
                catalog: InAppWorkspace.controls(on: screen),
                live: live?.controls ?? []
            ),
            appContext: InAppWorkspace.appContext(for: screen)
        )
    }

    public func perform(_ command: InAppNavigationCommand) async -> InAppNavigationResult {
        switch command {
        case .open(let target):
            screen = target
            return InAppNavigationResult(
                didNavigate: true,
                screen: screen,
                message: "Opened \(target.rawValue). screen=\(target.rawValue)"
            )
        case .tap(let controlId):
            return activate(controlId)
        case .type(let controlId, let text):
            guard InAppWorkspace.control(id: controlId) != nil else {
                return InAppNavigationResult(
                    didNavigate: false,
                    screen: screen,
                    message: "Unknown in-app field \(controlId).",
                    succeeded: false
                )
            }
            fieldValues[controlId] = text
            extraVisibleText.append(text)
            return InAppNavigationResult(
                didNavigate: false,
                screen: screen,
                message: "Typed into \(controlId): \(text)"
            )
        case .invokeIntent(let name):
            guard let intent = FirstPartyAppIntents.resolve(name) else {
                return InAppNavigationResult(
                    didNavigate: false,
                    screen: screen,
                    message: "Unknown first-party App Intent.",
                    succeeded: false
                )
            }
            if let target = intent.screen {
                screen = target
            }
            return InAppNavigationResult(
                didNavigate: intent.screen != nil,
                screen: screen,
                message: "Invoked first-party App Intent \(intent.name). screen=\(screen.rawValue)"
            )
        }
    }

    private func activate(_ controlId: String) -> InAppNavigationResult {
        guard let control = InAppWorkspace.control(id: controlId) else {
            return InAppNavigationResult(
                didNavigate: false,
                screen: screen,
                message: "Unknown in-app control \(controlId).",
                succeeded: false
            )
        }
        if controlId == "nav.back" {
            screen = (screen == .settings || screen == .models) ? .agentMode : .chats
        } else if let destination = Self.destination(for: controlId) {
            screen = destination
        }
        return InAppNavigationResult(
            didNavigate: true,
            screen: screen,
            message: "Activated in-app control \(control.label). screen=\(screen.rawValue)"
        )
    }

    public static func destination(for controlId: String) -> InAppScreen? {
        switch controlId {
        case "nav.models":
            return .models
        case "nav.settings":
            return .settings
        case "nav.agentMode":
            return .agentMode
        case "nav.newChat", "chat.send":
            return .chat
        case "nav.chats":
            return .chats
        case "nav.back":
            return .agentMode
        default:
            return nil
        }
    }
}

public struct LiveWorkspaceObserver: AgentObserving {
    private let store: InAppWorkspaceStore

    public init(store: InAppWorkspaceStore = .shared) {
        self.store = store
    }

    public func observe(goal: String, context: AgentObservationContext) async throws -> AgentObservation {
        var observation = await store.snapshot(goal: goal)
        if !context.visibleText.isEmpty {
            observation.visibleText.append(contentsOf: context.visibleText)
        }
        if !context.controls.isEmpty {
            observation.controls = context.controls
        }
        if let result = context.lastResult {
            observation.visibleText.append(result.message)
        }
        return observation
    }
}
