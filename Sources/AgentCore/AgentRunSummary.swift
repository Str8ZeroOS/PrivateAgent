import Foundation

/// A user-facing summary of an Agent Mode run, in the shared answer style:
/// the outcome first, then each sub-goal with its status and reason, then
/// what the user should do next.
public struct AgentRunSummary: Sendable, Equatable {
    public enum Outcome: String, Sendable, Equatable {
        case done
        case notVerified
        case blocked
        case failed
        case cancelled
        case awaitingApproval
        case running
        case idle
    }

    public enum ItemStatus: String, Sendable, Equatable {
        case verified
        case blocked
        case failed
        case notStarted
        case inProgress
        /// Ran, but nothing checked the result (Run Plan Once).
        case unverified

        public var label: String {
            switch self {
            case .verified: return "verified"
            case .blocked: return "blocked"
            case .failed: return "failed"
            case .notStarted: return "not started"
            case .inProgress: return "in progress"
            case .unverified: return "ran, not verified"
            }
        }
    }

    public struct Item: Sendable, Equatable {
        public var index: Int
        public var text: String
        public var status: ItemStatus
        public var reason: String?

        public init(index: Int, text: String, status: ItemStatus, reason: String? = nil) {
            self.index = index
            self.text = text
            self.status = status
            self.reason = reason
        }
    }

    public var outcome: Outcome
    /// Outcome label, e.g. "Done", "Blocked".
    public var title: String
    /// One sentence after the title, e.g. "All 2 sub-goals verified."
    public var headline: String
    public var answer: String?
    public var items: [Item]
    public var nextSteps: [String]

    /// Markdown for the chat bubble / Agent Mode result card.
    public var markdown: String {
        var parts: [String] = ["**\(title).** \(headline)"]
        if let answer, !answer.isEmpty {
            parts.append("Answer: \(answer)")
        }
        if !items.isEmpty {
            parts.append(items.map { item in
                var line = "\(item.index). \(item.text): \(item.status.label)."
                if let reason = item.reason, !reason.isEmpty {
                    line += " \(AgentRunSummaryFormatter.sentence(reason))"
                }
                return line
            }.joined(separator: "\n"))
        }
        if nextSteps.count == 1 {
            parts.append("Next: \(nextSteps[0])")
        } else if nextSteps.count > 1 {
            parts.append("Next:\n" + nextSteps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// Same content without Markdown emphasis (for logs, Siri, history lists).
    public var plainText: String {
        markdown.replacingOccurrences(of: "**", with: "")
    }
}

public enum AgentRunSummaryFormatter {
    /// Summarizes a closed-loop run. Works the same for the rule-based and the
    /// local-model planner, because both produce an `AgentLoopSnapshot`.
    public static func summarize(_ snapshot: AgentLoopSnapshot) -> AgentRunSummary {
        let progress = snapshot.goalProgress
        let subGoals = progress?.subGoals ?? []
        let reason = snapshot.outcomeMessage.map(sentence)
        let outcome = outcome(for: snapshot)

        // Items: verified / blocked / failed come from the loop. When the run
        // stopped without marking a sub-goal, the first pending one is where it stopped.
        var stopMarked = subGoals.contains { $0.status == .blocked || $0.status == .failed }
        var items: [AgentRunSummary.Item] = []
        for (offset, subGoal) in subGoals.enumerated() {
            let status: AgentRunSummary.ItemStatus
            var itemReason = subGoal.detail
            switch subGoal.status {
            case .verified:
                status = .verified
            case .blocked:
                status = .blocked
            case .failed:
                status = .failed
            case .pending:
                if !stopMarked, [.failed, .blocked, .cancelled].contains(outcome) {
                    status = outcome == .failed ? .failed : (outcome == .blocked ? .blocked : .notStarted)
                    itemReason = outcome == .cancelled ? "The run was cancelled before this step." : snapshot.outcomeMessage
                    stopMarked = true
                } else if !stopMarked, [.running, .awaitingApproval].contains(outcome) {
                    status = .inProgress
                    itemReason = nil
                    stopMarked = true
                } else {
                    status = .notStarted
                    itemReason = nil
                }
            }
            items.append(AgentRunSummary.Item(index: offset + 1, text: subGoal.text, status: status, reason: itemReason))
        }

        let total = subGoals.count
        let verified = subGoals.filter { $0.status == .verified }.count
        let stoppedAt = items.first { $0.status == .blocked || $0.status == .failed }
        let headline: String
        switch outcome {
        case .done:
            headline = total > 0 ? "All \(total) \(plural(total, "sub-goal")) verified." : (reason ?? "The goal was verified.")
        case .notVerified:
            headline = total > 0
                ? "The run ended, but only \(verified) of \(total) \(plural(total, "sub-goal")) were verified."
                : "The run ended, but the result was not verified."
        case .blocked, .failed:
            if total > 0, let stoppedAt {
                headline = "\(verified) of \(total) \(plural(total, "sub-goal")) verified; stopped at \"\(stoppedAt.text)\"."
            } else {
                headline = reason ?? (outcome == .blocked ? "The run could not continue." : "The run failed.")
            }
        case .cancelled:
            headline = total > 0
                ? "You stopped the run after \(verified) of \(total) \(plural(total, "sub-goal")) were verified."
                : "You stopped the run."
        case .awaitingApproval:
            headline = snapshot.pendingApproval.map { sentence($0.reason) } ?? "The next step needs your approval."
        case .running:
            headline = "Step \(snapshot.agentStepCount) of \(AgentLoopLimits.default.maxAgentSteps) is running."
        case .idle:
            headline = "Nothing has run yet."
        }

        return AgentRunSummary(
            outcome: outcome,
            title: title(for: outcome),
            headline: headline,
            answer: outcome == .done ? progress?.finalAnswer : nil,
            items: items,
            nextSteps: nextSteps(outcome: outcome, snapshot: snapshot, stoppedAt: stoppedAt, subGoals: subGoals)
        )
    }

    /// Summarizes "Run Plan Once" (no observe/verify loop), so nothing is
    /// called done: completed actions are reported as "ran, not verified".
    public static func summarize(plan: AgentPlan, results: [ActionExecutionResult]) -> AgentRunSummary {
        var items: [AgentRunSummary.Item] = []
        for (offset, step) in plan.steps.enumerated() {
            let result = offset < results.count ? results[offset] : nil
            let status: AgentRunSummary.ItemStatus
            switch result?.status {
            case .completed?: status = .unverified
            case .failed?: status = .failed
            case .skipped?: status = .blocked
            case .pending?, .running?, nil: status = .notStarted
            }
            items.append(AgentRunSummary.Item(
                index: offset + 1,
                text: step.expectedResult ?? step.rationale,
                status: status,
                reason: result?.message
            ))
        }
        let failed = items.first { $0.status == .failed || $0.status == .blocked }
        let ran = items.filter { $0.status == .unverified }.count
        if let failed {
            return AgentRunSummary(
                outcome: failed.status == .failed ? .failed : .blocked,
                title: failed.status == .failed ? "Failed" : "Blocked",
                headline: "Step \(failed.index) did not run: \(sentence(failed.reason ?? "no reason given"))",
                items: items,
                nextSteps: ["Tap **Run Agent** instead; it observes and verifies each step and explains what is missing."]
            )
        }
        return AgentRunSummary(
            outcome: .notVerified,
            title: "Ran, not verified",
            headline: "\(ran) of \(items.count) \(plural(items.count, "step")) ran. Run Plan Once does not check the result.",
            items: items,
            nextSteps: ["Check the result yourself, or tap **Run Agent** to run and verify it."]
        )
    }

    // MARK: Helpers

    static func outcome(for snapshot: AgentLoopSnapshot) -> AgentRunSummary.Outcome {
        switch snapshot.phase {
        case .completed:
            // Honest status: "done" only when every sub-goal was verified.
            if let progress = snapshot.goalProgress, !progress.subGoals.isEmpty, !progress.allVerified {
                return .notVerified
            }
            return .done
        case .failed: return .failed
        case .blocked: return .blocked
        case .cancelled: return .cancelled
        case .awaitingApproval: return .awaitingApproval
        case .idle: return .idle
        case .understanding, .observing, .planning, .validating, .executing, .verifying, .recovering:
            return .running
        }
    }

    static func title(for outcome: AgentRunSummary.Outcome) -> String {
        switch outcome {
        case .done: return "Done"
        case .notVerified: return "Not verified"
        case .blocked: return "Blocked"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .awaitingApproval: return "Waiting for your approval"
        case .running: return "Running"
        case .idle: return "Not started"
        }
    }

    static func nextSteps(
        outcome: AgentRunSummary.Outcome,
        snapshot: AgentLoopSnapshot,
        stoppedAt: AgentRunSummary.Item?,
        subGoals: [AgentSubGoal]
    ) -> [String] {
        let message = snapshot.outcomeMessage ?? ""
        switch outcome {
        case .done:
            return ["Nothing else is needed."]
        case .notVerified:
            return ["Check the result yourself, then tap **Run Agent** again for anything still missing."]
        case .awaitingApproval:
            return ["Review the plan, then tap **Approve** to continue or **Cancel** to stop."]
        case .running:
            return ["Wait for the run to finish, or tap **Cancel** to stop it."]
        case .idle:
            return ["Type a goal, then tap **Run Agent**."]
        case .cancelled:
            return ["Tap **Run Agent** to start again."]
        case .blocked:
            if message == "Ask for a task before acting." {
                return ["Type what Str8ZeRO should do in the goal field, then tap **Run Agent**."]
            }
            if message == "User rejected the plan." {
                return ["Change the goal if needed, then tap **Run Agent** and approve the plan."]
            }
            let stoppedSubGoal = stoppedAt.flatMap { item in subGoals.first { $0.index == item.index - 1 } }
            if stoppedSubGoal?.kind == .externalApp {
                return [
                    "Do \"\(stoppedSubGoal?.text ?? "that step")\" yourself in that app.",
                    "To let Str8ZeRO do it, pair a Mac in **Agent Mode > Mac Bridge** (tap **Check Bridge**), turn on **Mac-assisted** under Allowed Modes, then tap **Run Agent** again."
                ]
            }
            if message.hasSuffix("?") {
                return ["Answer the question above in the goal field, then tap **Run Agent** again."]
            }
            return ["Fix what the reason above describes (for example, turn on the needed mode under Allowed Modes), then tap **Run Agent** again."]
        case .failed:
            if message.hasPrefix("Reached the maximum") {
                return ["Split the goal into smaller parts and run each one."]
            }
            return ["Check the reason above, then tap **Run Agent** to try again."]
        }
    }

    static func plural(_ count: Int, _ word: String) -> String {
        count == 1 ? word : word + "s"
    }

    /// Trims and makes sure the text ends like a sentence.
    public static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }
}
