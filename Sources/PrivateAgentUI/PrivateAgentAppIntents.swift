import AgentCore

#if canImport(AppIntents)
import AppIntents
#if canImport(UIKit)
import UIKit
#endif

public struct OpenModelManagerIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Model Manager"
    public static let description = IntentDescription("Open the Str8ZeRO on-device model manager.")

    public init() {}

    public func perform() async throws -> some IntentResult {
        await AppRouter.shared.open(.models)
        return .result()
    }
}

public struct OpenSettingsIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Settings"
    public static let description = IntentDescription("Open Str8ZeRO settings.")

    public init() {}

    public func perform() async throws -> some IntentResult {
        await AppRouter.shared.open(.settings)
        return .result()
    }
}

public struct StartChatIntent: AppIntent {
    public static let title: LocalizedStringResource = "Start Chat"
    public static let description = IntentDescription("Start a new Str8ZeRO chat.")

    public init() {}

    public func perform() async throws -> some IntentResult {
        await AppRouter.shared.open(.chat)
        return .result()
    }
}

public struct OpenAgentModeIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Agent Mode"
    public static let description = IntentDescription("Open Str8ZeRO Agent Mode.")

    public init() {}

    public func perform() async throws -> some IntentResult {
        await AppRouter.shared.open(.agentMode)
        return .result()
    }
}

public struct OpenURLIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open URL"
    public static let description = IntentDescription("Open a URL through Str8ZeRO, including first-party privateagent:// deep links.")

    @Parameter(title: "URL")
    public var url: URL

    public init() {
        self.url = InAppDeepLink.url(for: .agentMode)
    }

    public init(url: URL) {
        self.url = url
    }

    public func perform() async throws -> some IntentResult {
        if let screen = InAppDeepLink.screen(from: url) {
            await AppRouter.shared.open(screen)
            return .result()
        }

        #if canImport(UIKit)
        await MainActor.run {
            UIApplication.shared.open(url)
        }
        #endif
        return .result()
    }
}

public struct PrivateAgentShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenModelManagerIntent(),
            phrases: ["Open model manager in \(.applicationName)"],
            shortTitle: "Models",
            systemImageName: "square.grid.2x2"
        )
        AppShortcut(
            intent: OpenSettingsIntent(),
            phrases: ["Open settings in \(.applicationName)"],
            shortTitle: "Settings",
            systemImageName: "gear"
        )
        AppShortcut(
            intent: StartChatIntent(),
            phrases: ["Start a chat in \(.applicationName)"],
            shortTitle: "New Chat",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: OpenAgentModeIntent(),
            phrases: ["Open Agent Mode in \(.applicationName)"],
            shortTitle: "Agent Mode",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: OpenURLIntent(),
            phrases: ["Open a URL in \(.applicationName)"],
            shortTitle: "Open URL",
            systemImageName: "link"
        )
    }
}
#endif
