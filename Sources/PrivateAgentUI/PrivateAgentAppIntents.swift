import AgentCore

#if canImport(AppIntents)
import AppIntents

public struct OpenModelManagerIntent: AppIntent {
    public static var title: LocalizedStringResource = "Open Model Manager"
    public static var description = IntentDescription("Open the PrivateAgent on-device model manager.")

    public init() {}

    public func perform() async throws -> some IntentResult {
        await AppRouter.shared.open(.models)
        return .result()
    }
}

public struct OpenSettingsIntent: AppIntent {
    public static var title: LocalizedStringResource = "Open Settings"
    public static var description = IntentDescription("Open PrivateAgent settings.")

    public init() {}

    public func perform() async throws -> some IntentResult {
        await AppRouter.shared.open(.settings)
        return .result()
    }
}

public struct StartChatIntent: AppIntent {
    public static var title: LocalizedStringResource = "Start Chat"
    public static var description = IntentDescription("Start a new PrivateAgent chat.")

    public init() {}

    public func perform() async throws -> some IntentResult {
        await AppRouter.shared.open(.chat)
        return .result()
    }
}

public struct OpenAgentModeIntent: AppIntent {
    public static var title: LocalizedStringResource = "Open Agent Mode"
    public static var description = IntentDescription("Open PrivateAgent Agent Mode.")

    public init() {}

    public func perform() async throws -> some IntentResult {
        await AppRouter.shared.open(.agentMode)
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
    }
}
#endif
