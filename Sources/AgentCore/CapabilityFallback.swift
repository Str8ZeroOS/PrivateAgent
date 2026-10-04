import Foundation

public enum CapabilityFallback {
    /// App Store-safe capability order: in-app -> App Intents -> URL scheme -> Shortcuts -> Mac bridge.
    public static let modeChain: [AutomationMode] = [
        .inApp, .appIntents, .shortcuts, .macAssisted
    ]

    public static func alternateActions(
        for action: AgentAction,
        allowedModes: [AutomationMode]
    ) -> [AgentAction] {
        switch action {
        case .answer, .askUser, .wait:
            return []
        case .openURL(let url):
            var alternates: [AgentAction] = []
            if allowedModes.contains(.appIntents) {
                alternates.append(.invokeAppIntent("OpenURL"))
            }
            if allowedModes.contains(.shortcuts) {
                alternates.append(.runShortcut("Open URL"))
            }
            if allowedModes.contains(.macAssisted) {
                alternates.append(.handoff(AgentHandoff(target: .macAssisted, reason: "Open \(url) via Mac bridge.")))
            }
            return alternates
        case .runShortcut(let name):
            var alternates: [AgentAction] = []
            if allowedModes.contains(.appIntents) {
                alternates.append(.invokeAppIntent(name))
            }
            if allowedModes.contains(.macAssisted) {
                alternates.append(.handoff(AgentHandoff(target: .macAssisted, reason: "Run shortcut \(name) via Mac bridge.")))
            }
            return alternates
        case .invokeAppIntent(let name):
            var alternates: [AgentAction] = []
            if allowedModes.contains(.shortcuts) {
                alternates.append(.runShortcut(name))
            }
            if allowedModes.contains(.macAssisted) {
                alternates.append(.handoff(AgentHandoff(target: .macAssisted, reason: "Invoke \(name) via Mac bridge.")))
            }
            return alternates
        case .tap, .type, .scroll:
            if allowedModes.contains(.macAssisted) {
                return [.handoff(AgentHandoff(target: .macAssisted, reason: "Cross-app UI control requires Mac-assisted automation."))]
            }
            if allowedModes.contains(.webDriverAgent) {
                return [.handoff(AgentHandoff(target: .webDriverAgent, reason: "Cross-app UI control requires WebDriverAgent."))]
            }
            if allowedModes.contains(.jailbreak) {
                return [.handoff(AgentHandoff(target: .jailbreak, reason: "Cross-app UI control requires a privileged bridge."))]
            }
            return []
        case .handoff:
            return []
        }
    }
}
