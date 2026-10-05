import Foundation

public enum InAppScreen: String, Sendable, Codable, Equatable, CaseIterable {
    case chats
    case chat
    case models
    case settings
    case agentMode
}

public struct RegisteredAppIntent: Sendable, Codable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var summary: String
    public var screen: InAppScreen?
    public var controlId: String?

    public init(name: String, summary: String, screen: InAppScreen? = nil, controlId: String? = nil) {
        self.name = name
        self.summary = summary
        self.screen = screen
        self.controlId = controlId
    }
}

public enum FirstPartyAppIntents {
    public static let catalog: [RegisteredAppIntent] = [
        RegisteredAppIntent(name: "OpenModelManager", summary: "Open the on-device model manager.", screen: .models, controlId: "nav.models"),
        RegisteredAppIntent(name: "OpenSettings", summary: "Open PrivateAgent settings.", screen: .settings, controlId: "nav.settings"),
        RegisteredAppIntent(name: "StartChat", summary: "Start a new local chat.", screen: .chat, controlId: "nav.newChat"),
        RegisteredAppIntent(name: "OpenAgentMode", summary: "Open Agent Mode.", screen: .agentMode, controlId: "nav.agentMode"),
        RegisteredAppIntent(name: "OpenURL", summary: "Open a URL through the system handler.")
    ]

    public static func resolve(_ name: String) -> RegisteredAppIntent? {
        catalog.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    public static func matchingGoal(_ goal: String) -> RegisteredAppIntent? {
        let lowered = goal.lowercased()
        if containsAny(lowered, ["model manager", "models", "download model", "load a model"]) {
            return resolve("OpenModelManager")
        }
        if containsAny(lowered, ["agent mode", "run agent", "automation"]) {
            return resolve("OpenAgentMode")
        }
        if containsAny(lowered, ["new chat", "start chat", "start a conversation"]) {
            return resolve("StartChat")
        }
        if containsAny(lowered, ["privateagent settings", "app settings"])
            || (lowered.contains("settings") && !containsAny(lowered, ["iphone", "ios", "system settings", "settings app"])) {
            return resolve("OpenSettings")
        }
        return nil
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}

public enum InAppDeepLink {
    public static let scheme = "privateagent"

    public static func url(for screen: InAppScreen) -> URL {
        URL(string: "\(scheme)://\(screen.rawValue)")!
    }

    public static func screen(from raw: String) -> InAppScreen? {
        guard let url = URL(string: raw) else { return nil }
        return screen(from: url)
    }

    public static func screen(from url: URL) -> InAppScreen? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let host = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        let aliases = [
            "agent": InAppScreen.agentMode,
            "agentmode": .agentMode,
            "model": .models,
            "models": .models,
            "setting": .settings,
            "settings": .settings,
            "chat": .chat,
            "chats": .chats
        ]
        return aliases[host] ?? InAppScreen.allCases.first { $0.rawValue.lowercased() == host }
    }

    public static func screen(inGoal goal: String) -> InAppScreen? {
        if let screen = screen(from: goal) {
            return screen
        }
        guard let range = goal.range(of: "\(scheme)://", options: .caseInsensitive) else {
            return nil
        }
        let remainder = String(goal[range.lowerBound...])
        let token = remainder.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).first.map(String.init) ?? remainder
        return screen(from: token)
    }

    public static func intentName(for screen: InAppScreen) -> String? {
        switch screen {
        case .models:
            return "OpenModelManager"
        case .settings:
            return "OpenSettings"
        case .chat:
            return "StartChat"
        case .agentMode:
            return "OpenAgentMode"
        case .chats:
            return nil
        }
    }

    public static func controlId(for screen: InAppScreen) -> String? {
        switch screen {
        case .models:
            return "nav.models"
        case .settings:
            return "nav.settings"
        case .chat:
            return "nav.newChat"
        case .agentMode:
            return "nav.agentMode"
        case .chats:
            return "nav.chats"
        }
    }
}

public struct AccessibilitySnapshot: Sendable, Codable, Equatable {
    public var screen: InAppScreen
    public var visibleText: [String]
    public var controls: [AgentControl]
    public var traits: [String: String]
    public var capturedAt: Date

    public init(
        screen: InAppScreen,
        visibleText: [String] = [],
        controls: [AgentControl] = [],
        traits: [String: String] = [:],
        capturedAt: Date = Date()
    ) {
        self.screen = screen
        self.visibleText = visibleText
        self.controls = controls
        self.traits = traits
        self.capturedAt = capturedAt
    }
}

public enum AccessibilitySnapshotMerge {
    public static func visibleText(catalog: [String], live: AccessibilitySnapshot?) -> [String] {
        var text = catalog
        var seen = Set(catalog)
        guard let live else { return text }
        for item in live.visibleText where seen.insert(item).inserted {
            text.append(item)
        }
        for (key, value) in live.traits.sorted(by: { $0.key < $1.key }) where !value.isEmpty {
            let token = "\(key)=\(value)"
            if seen.insert(token).inserted {
                text.append(token)
            }
        }
        return text
    }

    public static func controls(catalog: [AgentControl], live: [AgentControl]) -> [AgentControl] {
        guard !live.isEmpty else { return catalog }
        var seen: Set<String> = []
        var result: [AgentControl] = []
        for control in live where seen.insert(control.id).inserted {
            result.append(control)
        }
        for control in catalog where seen.insert(control.id).inserted {
            result.append(control)
        }
        return result
    }
}

public enum InAppWorkspace {
    public static func appContext(for screen: InAppScreen) -> String {
        "PrivateAgent.\(screen.rawValue)"
    }

    public static func visibleText(on screen: InAppScreen) -> [String] {
        switch screen {
        case .chats:
            return ["Chats", "Search conversations", "New chat", "Models", "Settings", "Agent"]
        case .chat:
            return ["Chat", "Message", "Send", "Generating"]
        case .models:
            return ["Model Manager", "Download", "Local models"]
        case .settings:
            return ["Settings", "Generation", "System Prompt", "NVIDIA cloud"]
        case .agentMode:
            return ["Agent Mode", "Goal", "Run Agent", "Preview Plan", "Cancel", "Allowed Modes", "Mac Bridge"]
        }
    }

    public static func controls(on screen: InAppScreen) -> [AgentControl] {
        switch screen {
        case .chats:
            return [
                AgentControl(id: "nav.newChat", label: "New chat", role: .button),
                AgentControl(id: "nav.models", label: "Models", role: .button),
                AgentControl(id: "nav.settings", label: "Settings", role: .button),
                AgentControl(id: "nav.agentMode", label: "Agent", role: .button),
                AgentControl(id: "chats.search", label: "Search conversations", role: .textField)
            ]
        case .chat:
            return [
                AgentControl(id: "chat.compose", label: "Message", role: .textField),
                AgentControl(id: "chat.send", label: "Send", role: .button),
                AgentControl(id: "chat.settings", label: "Chat settings", role: .button)
            ]
        case .models:
            return [
                AgentControl(id: "models.download", label: "Download", role: .button),
                AgentControl(id: "nav.chats", label: "Chats", role: .button)
            ]
        case .settings:
            return [
                AgentControl(id: "settings.cloudToggle", label: "Use NVIDIA cloud", role: .toggle),
                AgentControl(id: "nav.chats", label: "Chats", role: .button)
            ]
        case .agentMode:
            return [
                AgentControl(id: "agent.goal", label: "Goal", role: .textField),
                AgentControl(id: "agent.run", label: "Run Agent", role: .button),
                AgentControl(id: "agent.preview", label: "Preview Plan", role: .button),
                AgentControl(id: "agent.cancel", label: "Cancel", role: .button),
                AgentControl(id: "nav.models", label: "Models", role: .button),
                AgentControl(id: "nav.settings", label: "Settings", role: .button),
                AgentControl(id: "nav.history", label: "History", role: .button)
            ]
        }
    }

    public static func allControls() -> [AgentControl] {
        var seen: Set<String> = []
        var result: [AgentControl] = []
        for screen in InAppScreen.allCases {
            for control in controls(on: screen) where seen.insert(control.id).inserted {
                result.append(control)
            }
        }
        return result
    }

    public static func control(id: String) -> AgentControl? {
        allControls().first { $0.id == id }
    }

    public static func screen(forControlId id: String) -> InAppScreen? {
        InAppScreen.allCases.first { controls(on: $0).contains(where: { $0.id == id }) }
    }

    public static func observation(goal: String, screen: InAppScreen = .agentMode) -> AgentObservation {
        AgentObservation(
            source: .privateAgentApp,
            userGoal: goal,
            visibleText: visibleText(on: screen),
            controls: controls(on: screen),
            appContext: appContext(for: screen)
        )
    }
}
