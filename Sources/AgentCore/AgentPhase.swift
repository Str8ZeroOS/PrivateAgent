import Foundation

public enum AgentPhase: String, Sendable, Codable, Equatable, CaseIterable {
    case idle
    case understanding
    case observing
    case planning
    case validating
    case awaitingApproval
    case executing
    case verifying
    case recovering
    case completed
    case failed
    case cancelled
    case blocked

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .blocked:
            return true
        case .idle, .understanding, .observing, .planning, .validating, .awaitingApproval, .executing, .verifying, .recovering:
            return false
        }
    }

    public var title: String {
        switch self {
        case .idle: return "Idle"
        case .understanding: return "Understanding"
        case .observing: return "Observing"
        case .planning: return "Planning"
        case .validating: return "Validating"
        case .awaitingApproval: return "Awaiting Approval"
        case .executing: return "Executing"
        case .verifying: return "Verifying"
        case .recovering: return "Recovering"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .blocked: return "Blocked"
        }
    }
}

public enum AgentStateMachineError: Error, Sendable, Equatable, LocalizedError {
    case illegalTransition(from: AgentPhase, to: AgentPhase)
    case alreadyTerminal(AgentPhase)

    public var errorDescription: String? {
        switch self {
        case .illegalTransition(let from, let to):
            return "Illegal agent transition from \(from.rawValue) to \(to.rawValue)."
        case .alreadyTerminal(let phase):
            return "Agent is already in terminal phase \(phase.rawValue)."
        }
    }
}

public struct AgentStateMachine: Sendable, Equatable {
    public private(set) var phase: AgentPhase

    public init(phase: AgentPhase = .idle) {
        self.phase = phase
    }

    public mutating func transition(to newPhase: AgentPhase) throws {
        guard Self.isAllowed(from: phase, to: newPhase) else {
            if phase.isTerminal {
                throw AgentStateMachineError.alreadyTerminal(phase)
            }
            throw AgentStateMachineError.illegalTransition(from: phase, to: newPhase)
        }
        phase = newPhase
    }

    public static func isAllowed(from: AgentPhase, to: AgentPhase) -> Bool {
        if from == to { return true }
        if from.isTerminal { return false }

        switch to {
        case .cancelled, .failed:
            return true
        case .blocked:
            return from != .idle
        default:
            break
        }

        switch from {
        case .idle:
            return to == .understanding
        case .understanding:
            return to == .observing
        case .observing:
            return to == .planning || to == .recovering
        case .planning:
            return to == .validating || to == .recovering
        case .validating:
            return to == .awaitingApproval || to == .executing || to == .recovering
        case .awaitingApproval:
            return to == .executing
        case .executing:
            return to == .verifying || to == .recovering
        case .verifying:
            return to == .observing || to == .planning || to == .recovering || to == .completed
        case .recovering:
            return to == .observing || to == .planning || to == .executing
        case .completed, .failed, .cancelled, .blocked:
            return false
        }
    }
}
