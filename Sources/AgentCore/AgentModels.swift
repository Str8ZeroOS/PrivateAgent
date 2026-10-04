import Foundation

public struct AgentObservation: Sendable, Codable, Equatable {
    public var source: ObservationSource
    public var userGoal: String
    public var visibleText: [String]
    public var controls: [AgentControl]
    public var appContext: String?
    public var timestamp: Date

    public init(
        source: ObservationSource,
        userGoal: String,
        visibleText: [String] = [],
        controls: [AgentControl] = [],
        appContext: String? = nil,
        timestamp: Date = Date()
    ) {
        self.source = source
        self.userGoal = userGoal
        self.visibleText = visibleText
        self.controls = controls
        self.appContext = appContext
        self.timestamp = timestamp
    }
}

public enum ObservationSource: String, Sendable, Codable, Equatable {
    case privateAgentApp
    case appIntent
    case shortcuts
    case macBridge
    case webDriverAgent
    case jailbreakBridge
    case userProvided
}

public struct AgentControl: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var role: ControlRole
    public var isEnabled: Bool
    public var hint: String?

    public init(id: String, label: String, role: ControlRole, isEnabled: Bool = true, hint: String? = nil) {
        self.id = id
        self.label = label
        self.role = role
        self.isEnabled = isEnabled
        self.hint = hint
    }
}

public enum ControlRole: String, Sendable, Codable, Equatable {
    case button
    case textField
    case toggle
    case menu
    case link
    case listItem
    case unknown
}

public struct AgentPlan: Sendable, Codable, Equatable {
    public var summary: String
    public var steps: [AgentStep]
    public var requiresUserApproval: Bool
    public var risk: AgentRisk

    public init(summary: String, steps: [AgentStep], requiresUserApproval: Bool = false, risk: AgentRisk = .low) {
        self.summary = summary
        self.steps = steps
        self.requiresUserApproval = requiresUserApproval
        self.risk = risk
    }
}

public struct AgentStep: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var action: AgentAction
    public var rationale: String
    public var status: AgentStepStatus

    public init(id: UUID = UUID(), action: AgentAction, rationale: String, status: AgentStepStatus = .pending) {
        self.id = id
        self.action = action
        self.rationale = rationale
        self.status = status
    }
}

public enum AgentAction: Sendable, Codable, Equatable {
    case answer(String)
    case askUser(String)
    case openURL(String)
    case runShortcut(String)
    case invokeAppIntent(String)
    case tap(controlId: String)
    case type(controlId: String, text: String)
    case scroll(direction: ScrollDirection)
    case wait(seconds: Double)
    case handoff(AgentHandoff)
}

public enum ScrollDirection: String, Sendable, Codable, Equatable {
    case up
    case down
    case left
    case right
}

public struct AgentHandoff: Sendable, Codable, Equatable {
    public var target: AutomationMode
    public var reason: String

    public init(target: AutomationMode, reason: String) {
        self.target = target
        self.reason = reason
    }
}

public enum AgentStepStatus: String, Sendable, Codable, Equatable {
    case pending
    case running
    case completed
    case failed
    case skipped
}

public enum AgentRisk: String, Sendable, Codable, Equatable, Comparable {
    case low
    case medium
    case high

    public static func < (lhs: AgentRisk, rhs: AgentRisk) -> Bool {
        let order: [AgentRisk] = [.low, .medium, .high]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}
