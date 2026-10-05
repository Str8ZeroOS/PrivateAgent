import Testing
@testable import AgentCore

@Suite("Agent state machine")
struct AgentStateMachineTests {
    @Test("starts idle and accepts the closed-loop path")
    func followsClosedLoopPath() throws {
        var machine = AgentStateMachine()
        #expect(machine.phase == .idle)
        #expect(!machine.phase.isTerminal)

        try machine.transition(to: .understanding)
        try machine.transition(to: .observing)
        try machine.transition(to: .planning)
        try machine.transition(to: .validating)
        try machine.transition(to: .awaitingApproval)
        try machine.transition(to: .executing)
        try machine.transition(to: .verifying)
        try machine.transition(to: .completed)

        #expect(machine.phase == .completed)
        #expect(machine.phase.isTerminal)
    }

    @Test("allows recovery and terminal failure from active phases")
    func allowsRecoveryAndFailure() throws {
        var machine = AgentStateMachine(phase: .executing)
        try machine.transition(to: .recovering)
        try machine.transition(to: .observing)
        try machine.transition(to: .planning)
        try machine.transition(to: .failed)
        #expect(machine.phase == .failed)
    }

    @Test("rejects illegal transitions and mutation after completion")
    func rejectsIllegalTransitions() {
        var machine = AgentStateMachine()
        #expect(throws: AgentStateMachineError.illegalTransition(from: .idle, to: .executing)) {
            try machine.transition(to: .executing)
        }

        var completed = AgentStateMachine(phase: .completed)
        #expect(throws: AgentStateMachineError.alreadyTerminal(.completed)) {
            try completed.transition(to: .idle)
        }
    }

    @Test("terminal phases are completed failed cancelled and blocked")
    func terminalPhases() {
        for phase in AgentPhase.allCases {
            switch phase {
            case .completed, .failed, .cancelled, .blocked:
                #expect(phase.isTerminal)
            default:
                #expect(!phase.isTerminal)
            }
        }
    }
}
