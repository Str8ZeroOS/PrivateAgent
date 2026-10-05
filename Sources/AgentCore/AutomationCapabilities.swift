import Foundation

public enum AutomationMode: String, Sendable, Codable, CaseIterable, Equatable {
    case inApp
    case appIntents
    case shortcuts
    case macAssisted
    case webDriverAgent
    case jailbreak
}

public struct AutomationCapability: Sendable, Codable, Equatable, Identifiable {
    public var id: AutomationMode { mode }
    public var mode: AutomationMode
    public var title: String
    public var isAppStoreSafe: Bool
    public var canReadExternalApps: Bool
    public var canControlExternalApps: Bool
    public var notes: String

    public init(
        mode: AutomationMode,
        title: String,
        isAppStoreSafe: Bool,
        canReadExternalApps: Bool,
        canControlExternalApps: Bool,
        notes: String
    ) {
        self.mode = mode
        self.title = title
        self.isAppStoreSafe = isAppStoreSafe
        self.canReadExternalApps = canReadExternalApps
        self.canControlExternalApps = canControlExternalApps
        self.notes = notes
    }
}

public enum AutomationCapabilities {
    public static let supportedModes: [AutomationCapability] = [
        AutomationCapability(
            mode: .inApp,
            title: "PrivateAgent app workspace",
            isAppStoreSafe: true,
            canReadExternalApps: false,
            canControlExternalApps: false,
            notes: "Best default. The agent can plan, chat, manage models, and operate PrivateAgent-owned UI."
        ),
        AutomationCapability(
            mode: .appIntents,
            title: "App Intents",
            isAppStoreSafe: true,
            canReadExternalApps: false,
            canControlExternalApps: false,
            notes: "Good for explicit integrations exposed by apps and system features through intents."
        ),
        AutomationCapability(
            mode: .shortcuts,
            title: "Shortcuts",
            isAppStoreSafe: true,
            canReadExternalApps: false,
            canControlExternalApps: false,
            notes: "Useful for user-approved automations, handoffs, and repeatable routines."
        ),
        AutomationCapability(
            mode: .macAssisted,
            title: "Mac-assisted iPhone control",
            isAppStoreSafe: true,
            canReadExternalApps: true,
            canControlExternalApps: true,
            notes: "Closest App-Store-safe path to Android-style control when paired with a trusted Mac bridge. Opt-in iPhone Mirroring observation reads the Mac-side mirrored window, not iOS Accessibility."
        ),
        AutomationCapability(
            mode: .webDriverAgent,
            title: "WebDriverAgent/XCTest bridge",
            isAppStoreSafe: false,
            canReadExternalApps: true,
            canControlExternalApps: true,
            notes: "Useful for developer/test devices. Not a normal consumer-device runtime feature."
        ),
        AutomationCapability(
            mode: .jailbreak,
            title: "Jailbreak/private entitlement bridge",
            isAppStoreSafe: false,
            canReadExternalApps: true,
            canControlExternalApps: true,
            notes: "Most Android-like, but fragile, device-specific, and outside normal App Store constraints."
        )
    ]

    public static func capability(for mode: AutomationMode) -> AutomationCapability? {
        supportedModes.first { $0.mode == mode }
    }
}
