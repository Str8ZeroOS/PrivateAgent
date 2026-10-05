import Foundation

public enum AgentSubGoalKind: String, Sendable, Codable, Equatable {
    case navigateInApp
    case returnToScreen
    case reply
    case externalApp
    case generic
}

public enum AgentSubGoalStatus: String, Sendable, Codable, Equatable {
    case pending
    case verified
    case failed
    case blocked
}

public struct AgentSubGoal: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var index: Int
    public var text: String
    public var kind: AgentSubGoalKind
    public var screen: InAppScreen?
    public var replyText: String?
    public var status: AgentSubGoalStatus
    public var detail: String?

    public init(
        id: UUID = UUID(),
        index: Int,
        text: String,
        kind: AgentSubGoalKind,
        screen: InAppScreen? = nil,
        replyText: String? = nil,
        status: AgentSubGoalStatus = .pending,
        detail: String? = nil
    ) {
        self.id = id
        self.index = index
        self.text = text
        self.kind = kind
        self.screen = screen
        self.replyText = replyText
        self.status = status
        self.detail = detail
    }
}

public struct AgentGoalProgress: Sendable, Codable, Equatable {
    public var originalGoal: String
    public var subGoals: [AgentSubGoal]
    public var finalAnswer: String?

    public init(originalGoal: String, subGoals: [AgentSubGoal], finalAnswer: String? = nil) {
        self.originalGoal = originalGoal
        self.subGoals = subGoals
        self.finalAnswer = finalAnswer
    }

    public var nextPending: AgentSubGoal? {
        subGoals.first { $0.status == .pending }
    }

    public var allVerified: Bool {
        !subGoals.isEmpty && subGoals.allSatisfy { $0.status == .verified }
    }

    public var verifiedCount: Int {
        subGoals.filter { $0.status == .verified }.count
    }
}

public enum GoalBreakdown {
    public static func parse(_ goal: String) -> AgentGoalProgress {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let clauses = splitClauses(trimmed)
        let subGoals = clauses.enumerated().map { index, clause in
            classify(clause, index: index)
        }
        return AgentGoalProgress(originalGoal: trimmed, subGoals: subGoals)
    }

    public static func firstClause(of goal: String) -> String {
        parse(goal).subGoals.first?.text ?? goal.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func parseReply(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        let prefixes = ["reply ", "say ", "answer with ", "answer "]
        for prefix in prefixes {
            guard lowered.hasPrefix(prefix) else { continue }
            var rest = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if rest.count >= 2, rest.hasPrefix("\""), rest.hasSuffix("\"") {
                rest = String(rest.dropFirst().dropLast())
            }
            rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: ".,!"))
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    public static func isUndriveableExternalApp(_ text: String) -> Bool {
        classify(text, index: 0).kind == .externalApp
    }

    public static func evaluating(
        goal: String,
        history: [StepRunRecord],
        observation: AgentObservation
    ) -> AgentGoalProgress {
        var progress = parse(goal)
        apply(history: history, observation: observation, to: &progress)
        return progress
    }

    public static func apply(
        history: [StepRunRecord],
        observation: AgentObservation,
        to progress: inout AgentGoalProgress
    ) {
        var cursor = 0
        for record in history {
            while cursor < progress.subGoals.count, progress.subGoals[cursor].status != .pending {
                cursor += 1
            }
            guard cursor < progress.subGoals.count else { break }
            if satisfies(progress.subGoals[cursor], record: record, observation: observation) {
                progress.subGoals[cursor].status = .verified
                progress.subGoals[cursor].detail = record.verification?.message ?? record.execution.message
                if progress.subGoals[cursor].kind == .reply {
                    progress.finalAnswer = progress.subGoals[cursor].replyText ?? replyText(from: record)
                }
                cursor += 1
            }
        }
        if progress.allVerified, progress.finalAnswer == nil {
            progress.finalAnswer = lastAnswer(in: history)
        }
    }

    public static func cannotDriveReason(for subGoal: AgentSubGoal) -> String {
        let label = subGoal.text.isEmpty ? "this step" : "'\(subGoal.text)'"
        return "Cannot complete \(label): iOS cannot drive another app (for example Apple Notes) from inside Str8ZeRO."
    }

    public static func isLiveExternalObservation(_ source: ObservationSource) -> Bool {
        switch source {
        case .macBridge, .iphoneMirroring, .webDriverAgent, .jailbreakBridge:
            return true
        case .privateAgentApp, .appIntent, .shortcuts, .userProvided:
            return false
        }
    }

    private static func splitClauses(_ goal: String) -> [String] {
        guard !goal.isEmpty else { return [] }
        let pattern = #"\s*(?:,\s*)?(?:\band\s+then\b|\bthen\b|\bafter that\b|\bafterwards\b|\bafterward\b)\s+"#
        let parts: [String]
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let range = NSRange(goal.startIndex..<goal.endIndex, in: goal)
            var last = goal.startIndex
            var clauses: [String] = []
            for match in regex.matches(in: goal, options: [], range: range) {
                guard let matchRange = Range(match.range, in: goal) else { continue }
                let clause = String(goal[last..<matchRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !clause.isEmpty {
                    clauses.append(stripLeadingThen(clause))
                }
                last = matchRange.upperBound
            }
            let tail = String(goal[last...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty {
                clauses.append(stripLeadingThen(tail))
            }
            parts = clauses
        } else {
            parts = [goal]
        }

        if parts.count > 1 {
            return parts
        }
        return splitOnActionCommas(goal)
    }

    private static func splitOnActionCommas(_ goal: String) -> [String] {
        let commaParts = goal
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard commaParts.count > 1, commaParts.allSatisfy(looksLikeActionClause) else {
            return [goal]
        }
        return commaParts
    }

    private static func looksLikeActionClause(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let verbs = ["open", "return", "go ", "go back", "reply", "say ", "tap", "create", "navigate", "show", "close", "back"]
        return verbs.contains { lowered.hasPrefix($0) || lowered.contains(" \($0)") }
    }

    private static func stripLeadingThen(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["and then ", "then "] {
            if result.lowercased().hasPrefix(prefix) {
                result = String(result.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return result
    }

    private static func classify(_ text: String, index: Int) -> AgentSubGoal {
        let trimmed = stripLeadingThen(text)
        let lowered = trimmed.lowercased()

        if let reply = parseReply(trimmed) {
            return AgentSubGoal(index: index, text: trimmed, kind: .reply, replyText: reply)
        }

        if isReturnPhrase(lowered) {
            return AgentSubGoal(
                index: index,
                text: trimmed,
                kind: .returnToScreen,
                screen: inferredScreen(in: lowered) ?? .agentMode
            )
        }

        if isUndriveableExternalPhrase(lowered) {
            return AgentSubGoal(index: index, text: trimmed, kind: .externalApp)
        }

        if let screen = inferredInAppNavigation(in: lowered) {
            return AgentSubGoal(index: index, text: trimmed, kind: .navigateInApp, screen: screen)
        }

        return AgentSubGoal(index: index, text: trimmed, kind: .generic)
    }

    private static func isReturnPhrase(_ lowered: String) -> Bool {
        containsAny(lowered, ["return to", "go back", "back to", "return back"])
    }

    private static func isUndriveableExternalPhrase(_ lowered: String) -> Bool {
        if containsAny(lowered, [
            "apple notes", "notes app", "iphone notes", "create a new note",
            "create a note", "new note titled", "note titled"
        ]) {
            return true
        }
        if lowered.contains("note") && containsAny(lowered, ["create", "titled", "apple notes"]) {
            return true
        }
        return containsAny(lowered, [
            "instagram", "youtube", "telegram", "whatsapp", "tiktok",
            "chrome", "safari", "reminders app", "mail app", "messages app"
        ])
    }

    private static func inferredInAppNavigation(in lowered: String) -> InAppScreen? {
        if containsAny(lowered, ["iphone settings", "ios settings", "system settings", "settings app"]) {
            return nil
        }
        if containsAny(lowered, ["model manager", "models", "download model"]) {
            return .models
        }
        if containsAny(lowered, ["agent mode", "run agent"]) {
            return .agentMode
        }
        if containsAny(lowered, ["new chat", "start chat"]) {
            return .chat
        }
        if containsAny(lowered, ["settings"]) {
            return .settings
        }
        if containsAny(lowered, ["chats", "conversation list"]) {
            return .chats
        }
        return inferredScreen(in: lowered)
    }

    private static func inferredScreen(in lowered: String) -> InAppScreen? {
        if containsAny(lowered, ["agent mode", "agentmode"]) {
            return .agentMode
        }
        if containsAny(lowered, ["model manager", "models"]) {
            return .models
        }
        if containsAny(lowered, ["settings"]) {
            return .settings
        }
        if containsAny(lowered, ["new chat"]) {
            return .chat
        }
        if containsAny(lowered, ["chats"]) {
            return .chats
        }
        return nil
    }

    private static func satisfies(
        _ subGoal: AgentSubGoal,
        record: StepRunRecord,
        observation: AgentObservation
    ) -> Bool {
        let executionOK = record.execution.status == .completed
        guard executionOK else { return false }
        if record.outcome == .actionFailed || record.outcome == .skipped {
            return false
        }

        switch subGoal.kind {
        case .navigateInApp, .returnToScreen:
            if let screen = subGoal.screen, observationShows(screen, observation: observation) {
                return record.outcome != .actionUnverified
            }
            if let screen = subGoal.screen, actionTargets(record.step.action, screen: screen) {
                return record.verification?.verified == true || record.outcome == .actionVerified || record.outcome == .actionSuccess
            }
            return record.verification?.verified == true
        case .reply:
            let expected = subGoal.replyText ?? ""
            guard !expected.isEmpty else { return false }
            if case .answer(let text) = record.step.action {
                return text == expected || record.execution.message == expected
            }
            return record.execution.message == expected
        case .externalApp:
            return isLiveExternalObservation(observation.source) && record.verification?.verified == true
        case .generic:
            if case .answer(let text) = record.step.action {
                return !isUndriveableExternalApp(subGoal.text) && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if case .askUser = record.step.action {
                return true
            }
            return record.verification?.verified == true || record.outcome == .actionVerified
        }
    }

    private static func observationShows(_ screen: InAppScreen, observation: AgentObservation) -> Bool {
        if observation.appContext?.localizedCaseInsensitiveContains(screen.rawValue) == true {
            return true
        }
        let titles: [String]
        switch screen {
        case .settings:
            titles = ["Settings"]
        case .agentMode:
            titles = ["Agent Mode", "Run Agent"]
        case .models:
            titles = ["Model Manager", "Models"]
        case .chat:
            titles = ["Chat"]
        case .chats:
            titles = ["Chats"]
        }
        return observation.visibleText.contains { line in
            titles.contains { line.localizedCaseInsensitiveContains($0) }
        }
    }

    private static func actionTargets(_ action: AgentAction, screen: InAppScreen) -> Bool {
        switch action {
        case .tap(let controlId):
            return InAppDeepLink.controlId(for: screen) == controlId || InAppWorkspace.screen(forControlId: controlId) == screen
        case .invokeAppIntent(let name):
            return FirstPartyAppIntents.resolve(name)?.screen == screen
        case .openURL(let url):
            return InAppDeepLink.screen(from: url) == screen
        default:
            return false
        }
    }

    private static func replyText(from record: StepRunRecord) -> String? {
        if case .answer(let text) = record.step.action {
            return text
        }
        return record.execution.message
    }

    private static func lastAnswer(in history: [StepRunRecord]) -> String? {
        for record in history.reversed() {
            if case .answer(let text) = record.step.action, record.execution.status == .completed {
                return text
            }
        }
        return nil
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}
