import Foundation
import Testing
@testable import AgentCore

@Suite("Answer style prompt")
struct AnswerStylePromptTests {
    @Test("style guide is applied for both providers", arguments: AssistantProvider.allCases)
    func appliedForBothProviders(provider: AssistantProvider) {
        let turns = AssistantPromptBuilder.messages(
            provider: provider,
            baseSystemPrompt: "You are a helpful assistant.",
            userText: "How do I turn on Wi-Fi?",
            styleEnabled: true
        )
        #expect(turns.first?.role == "system")
        #expect(turns.first?.content.hasPrefix("You are a helpful assistant.") == true)
        #expect(turns.first?.content.contains(AssistantStyleGuide.marker) == true)
        #expect(turns.first?.content.contains("Lead with the answer") == true)
        #expect(turns.first?.content.contains("numbered steps") == true)
        #expect(turns.last == AssistantChatTurn(role: "user", content: "How do I turn on Wi-Fi?"))
    }

    @Test("both providers get the identical style text")
    func identicalAcrossProviders() {
        let device = AssistantPromptBuilder.systemPrompt(base: "Base", provider: .onDevice, styleEnabled: true)
        let cloud = AssistantPromptBuilder.systemPrompt(base: "Base", provider: .cloudNVIDIA, styleEnabled: true)
        #expect(device == cloud)
        #expect(device == "Base\n\n" + AssistantStyleGuide.prompt)
    }

    @Test("toggle off leaves the user's system prompt unchanged")
    func disabled() {
        for provider in AssistantProvider.allCases {
            let prompt = AssistantPromptBuilder.systemPrompt(base: "You are terse.", provider: provider, styleEnabled: false)
            #expect(prompt == "You are terse.")
        }
    }

    @Test("cloud drops Qwen control lines, on-device keeps them")
    func controlLines() {
        let base = "/no_think\nYou are a helpful assistant."
        let device = AssistantPromptBuilder.systemPrompt(base: base, provider: .onDevice, styleEnabled: true)
        let cloud = AssistantPromptBuilder.systemPrompt(base: base, provider: .cloudNVIDIA, styleEnabled: true)
        #expect(device.hasPrefix("/no_think\n"))
        #expect(!cloud.contains("/no_think"))
        #expect(cloud.contains(AssistantStyleGuide.marker))
    }

    @Test("guide is never appended twice and works with an empty base")
    func idempotentAndEmptyBase() {
        let once = AssistantPromptBuilder.systemPrompt(base: "Base", provider: .onDevice, styleEnabled: true)
        let twice = AssistantPromptBuilder.systemPrompt(base: once, provider: .onDevice, styleEnabled: true)
        #expect(once == twice)
        #expect(AssistantPromptBuilder.systemPrompt(base: "  ", provider: .cloudNVIDIA, styleEnabled: true) == AssistantStyleGuide.prompt)
        #expect(AssistantPromptBuilder.systemPrompt(base: "", provider: .cloudNVIDIA, styleEnabled: false).isEmpty)
    }

    @Test("cloud history is kept in order between the system prompt and the new turn")
    func historyOrder() {
        let turns = AssistantPromptBuilder.messages(
            provider: .cloudNVIDIA,
            baseSystemPrompt: "Base",
            history: [
                AssistantChatTurn(role: "user", content: "hi"),
                AssistantChatTurn(role: "assistant", content: ""),
                AssistantChatTurn(role: "system", content: "injected"),
                AssistantChatTurn(role: "assistant", content: "Hello."),
            ],
            userText: "next",
            styleEnabled: true
        )
        #expect(turns.map(\.role) == ["system", "user", "assistant", "user"])
        #expect(turns.map(\.content).dropFirst() == ["hi", "Hello.", "next"])
    }

    @Test("setting defaults to on and respects an explicit off")
    func preferenceDefault() {
        let suite = "PrivateAgent.AnswerStyleTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        #expect(AssistantStylePreferences.isEnabled(defaults: defaults))
        defaults.set(false, forKey: AssistantStylePreferences.enabledKey)
        #expect(!AssistantStylePreferences.isEnabled(defaults: defaults))
    }

    @Test("Agent Mode planner prompt carries the answer-text style only when enabled")
    func plannerPrompt() {
        let observation = AgentObservation(source: .privateAgentApp, userGoal: "Open Settings")
        let on = AgentPromptCompiler(answerStyleEnabled: true).compilePrompt(observation: observation, allowedModes: [.inApp])
        let off = AgentPromptCompiler(answerStyleEnabled: false).compilePrompt(observation: observation, allowedModes: [.inApp])
        #expect(on.contains(AssistantStyleGuide.agentActionTextPrompt))
        #expect(!off.contains(AssistantStyleGuide.agentActionTextPrompt))
        #expect(on.contains("return only valid JSON"))
    }
}

@Suite("Agent run summary formatter")
struct AgentRunSummaryFormatterTests {
    private func subGoal(_ index: Int, _ text: String, _ kind: AgentSubGoalKind, _ status: AgentSubGoalStatus, _ detail: String? = nil) -> AgentSubGoal {
        AgentSubGoal(index: index, text: text, kind: kind, status: status, detail: detail)
    }

    @Test("completed run leads with Done, lists verified sub-goals, and the answer")
    func done() {
        let snapshot = AgentLoopSnapshot(
            phase: .completed,
            goal: "Open Settings, then reply LOOP_OK",
            outcomeMessage: "All 2 sub-goal(s) verified.",
            goalProgress: AgentGoalProgress(
                originalGoal: "Open Settings, then reply LOOP_OK",
                subGoals: [
                    subGoal(0, "Open Settings", .navigateInApp, .verified, "Screen is settings"),
                    subGoal(1, "reply LOOP_OK", .reply, .verified, "Answered LOOP_OK"),
                ],
                finalAnswer: "LOOP_OK"
            )
        )
        let summary = AgentRunSummaryFormatter.summarize(snapshot)
        #expect(summary.outcome == .done)
        #expect(summary.markdown == """
        **Done.** All 2 sub-goals verified.

        Answer: LOOP_OK

        1. Open Settings: verified. Screen is settings.
        2. reply LOOP_OK: verified. Answered LOOP_OK.

        Next: Nothing else is needed.
        """)
        #expect(!summary.plainText.contains("**"))
    }

    @Test("completed phase without every sub-goal verified is not called done")
    func honestNotVerified() {
        let snapshot = AgentLoopSnapshot(
            phase: .completed,
            goalProgress: AgentGoalProgress(originalGoal: "a, then b", subGoals: [
                subGoal(0, "a", .generic, .verified),
                subGoal(1, "b", .generic, .pending),
            ])
        )
        let summary = AgentRunSummaryFormatter.summarize(snapshot)
        #expect(summary.outcome == .notVerified)
        #expect(summary.title == "Not verified")
        #expect(!summary.markdown.contains("Done"))
        #expect(summary.headline.contains("1 of 2"))
    }

    @Test("blocked external-app step: outcome, per-step reason, and numbered next steps")
    func blockedExternalApp() {
        let reason = "Cannot complete 'Create a note in Apple Notes': iOS cannot drive another app (for example Apple Notes) from inside Str8ZeRO."
        let snapshot = AgentLoopSnapshot(
            phase: .blocked,
            outcomeMessage: reason,
            goalProgress: AgentGoalProgress(originalGoal: "x", subGoals: [
                subGoal(0, "Open Settings", .navigateInApp, .verified, "Screen is settings"),
                subGoal(1, "Create a note in Apple Notes", .externalApp, .blocked, reason),
                subGoal(2, "reply done", .reply, .pending),
            ])
        )
        let summary = AgentRunSummaryFormatter.summarize(snapshot)
        #expect(summary.outcome == .blocked)
        #expect(summary.markdown.hasPrefix("**Blocked.** 1 of 3 sub-goals verified; stopped at \"Create a note in Apple Notes\"."))
        #expect(summary.items.map(\.status) == [.verified, .blocked, .notStarted])
        #expect(summary.items[1].reason == reason)
        #expect(summary.markdown.contains("3. reply done: not started."))
        #expect(summary.nextSteps.count == 2)
        #expect(summary.markdown.contains("Next:\n1. Do \"Create a note in Apple Notes\" yourself in that app."))
        #expect(summary.markdown.contains("**Check Bridge**"))
        #expect(summary.answer == nil)
    }

    @Test("failed run marks the step it stopped at with the reason")
    func failedStopsAtFirstPending() {
        let snapshot = AgentLoopSnapshot(
            phase: .failed,
            outcomeMessage: "Reached the maximum of 8 agent steps",
            goalProgress: AgentGoalProgress(originalGoal: "x", subGoals: [
                subGoal(0, "Open Models", .navigateInApp, .pending),
                subGoal(1, "reply ok", .reply, .pending),
            ])
        )
        let summary = AgentRunSummaryFormatter.summarize(snapshot)
        #expect(summary.items.map(\.status) == [.failed, .notStarted])
        #expect(summary.items[0].reason == "Reached the maximum of 8 agent steps")
        #expect(summary.markdown.contains("1. Open Models: failed. Reached the maximum of 8 agent steps."))
        #expect(summary.nextSteps == ["Split the goal into smaller parts and run each one."])
    }

    @Test("no sub-goals: the reason goes in the headline")
    func blockedWithoutSubGoals() {
        let summary = AgentRunSummaryFormatter.summarize(AgentLoopSnapshot(phase: .blocked, outcomeMessage: "Ask for a task before acting."))
        #expect(summary.markdown.hasPrefix("**Blocked.** Ask for a task before acting."))
        #expect(summary.nextSteps.first?.contains("goal field") == true)
    }

    @Test("rejected, cancelled, awaiting approval and running states")
    func otherStates() {
        let rejected = AgentRunSummaryFormatter.summarize(AgentLoopSnapshot(phase: .blocked, outcomeMessage: "User rejected the plan."))
        #expect(rejected.nextSteps.first?.contains("approve") == true)

        let cancelled = AgentRunSummaryFormatter.summarize(AgentLoopSnapshot(phase: .cancelled, outcomeMessage: "Run cancelled."))
        #expect(cancelled.title == "Cancelled")
        #expect(cancelled.nextSteps == ["Tap **Run Agent** to start again."])

        let plan = AgentPlan(summary: "s", steps: [])
        let waiting = AgentRunSummaryFormatter.summarize(AgentLoopSnapshot(
            phase: .awaitingApproval,
            pendingApproval: AgentApprovalRequest(plan: plan, reason: "Opening a URL needs approval", risk: .medium)
        ))
        #expect(waiting.markdown.hasPrefix("**Waiting for your approval.** Opening a URL needs approval."))

        let running = AgentRunSummaryFormatter.summarize(AgentLoopSnapshot(
            phase: .executing,
            agentStepCount: 2,
            goalProgress: AgentGoalProgress(originalGoal: "x", subGoals: [subGoal(0, "a", .generic, .verified), subGoal(1, "b", .generic, .pending)])
        ))
        #expect(running.outcome == .running)
        #expect(running.items.map(\.status) == [.verified, .inProgress])
    }

    @Test("rule-based closed loop produces a Done summary")
    func ruleBasedLoopDone() async {
        let store = InAppWorkspaceStore(screen: .agentMode)
        let loop = AgentLoop(configuration: AgentLoopConfiguration(
            observer: LiveWorkspaceObserver(store: store),
            planner: RuleBasedAgentPlanner(),
            executor: InAppActionExecutor(navigator: store),
            approval: AutoApprovingHandler(),
            allowedModes: [.inApp, .appIntents]
        ))
        let snapshot = await loop.run(goal: "Open Settings, then reply LOOP_OK")
        let summary = AgentRunSummaryFormatter.summarize(snapshot)
        #expect(summary.outcome == .done)
        #expect(summary.markdown.hasPrefix("**Done.**"))
        #expect(summary.answer == "LOOP_OK")
        #expect(summary.items.allSatisfy { $0.status == .verified })
    }

    @Test("rule-based closed loop on an Apple Notes goal produces a Blocked summary")
    func ruleBasedLoopBlocked() async {
        let store = InAppWorkspaceStore(screen: .agentMode)
        let loop = AgentLoop(configuration: AgentLoopConfiguration(
            observer: LiveWorkspaceObserver(store: store),
            planner: RuleBasedAgentPlanner(),
            executor: InAppActionExecutor(navigator: store),
            approval: AutoApprovingHandler(),
            allowedModes: [.inApp, .appIntents]
        ))
        let snapshot = await loop.run(goal: "Create a new note titled Agent Test with the body hello from Str8ZeRO")
        let summary = AgentRunSummaryFormatter.summarize(snapshot)
        #expect(summary.outcome == .blocked)
        #expect(!summary.markdown.contains("Done"))
        #expect(summary.items.contains { $0.status == .blocked && ($0.reason ?? "").contains("another app") })
        #expect(summary.nextSteps.count == 2)
    }

    @Test("Run Plan Once is reported as ran-not-verified, never done")
    func runPlanOnce() {
        let plan = AgentPlan(summary: "Open", steps: [
            AgentStep(action: .openURL("privateagent://settings"), rationale: "Open Settings"),
            AgentStep(action: .answer("ok"), rationale: "Reply ok"),
        ])
        let ok = AgentRunSummaryFormatter.summarize(plan: plan, results: [
            ActionExecutionResult(action: .openURL("privateagent://settings"), status: .completed, message: "Opened settings"),
            ActionExecutionResult(action: .answer("ok"), status: .completed, message: "ok"),
        ])
        #expect(ok.outcome == .notVerified)
        #expect(ok.items.map(\.status) == [.unverified, .unverified])
        #expect(!ok.markdown.contains("Done"))

        let failed = AgentRunSummaryFormatter.summarize(plan: plan, results: [
            ActionExecutionResult(action: .openURL("privateagent://settings"), status: .failed, message: "No handler"),
        ])
        #expect(failed.outcome == .failed)
        #expect(failed.headline == "Step 1 did not run: No handler.")
        #expect(failed.items.map(\.status) == [.failed, .notStarted])
    }
}

@Suite("Markdown block parser")
struct MarkdownBlockParserTests {
    @Test("paragraphs, numbered steps, bullets, code and links")
    func mixedReply() {
        let text = """
        **Wi-Fi is off.** Turn it on in Settings.

        1. Open **Settings**.
        2. Tap **Wi-Fi**.
        3. Turn on `Wi-Fi`.

        - Fast
        - Private

        ```bash
        swift test
        ```

        See [Apple Support](https://support.apple.com).
        """
        let blocks = MarkdownBlockParser.parse(text)
        #expect(blocks == [
            .paragraph("**Wi-Fi is off.** Turn it on in Settings."),
            .orderedList(start: 1, items: ["Open **Settings**.", "Tap **Wi-Fi**.", "Turn on `Wi-Fi`."]),
            .bulletList(["Fast", "Private"]),
            .codeBlock(language: "bash", code: "swift test"),
            .paragraph("See [Apple Support](https://support.apple.com)."),
        ])
    }

    @Test("headings, quotes, rules, loose numbered lists and continuation lines")
    func otherBlocks() {
        let text = "# Title\n> quoted\n> more\n---\n1) one\n\n2) two\n   still two\n* star"
        #expect(MarkdownBlockParser.parse(text) == [
            .heading(level: 1, text: "Title"),
            .quote("quoted\nmore"),
            .rule,
            .orderedList(start: 1, items: ["one", "two\nstill two"]),
            .bulletList(["star"]),
        ])
    }

    @Test("an unclosed fence while streaming becomes a code block")
    func streamingFence() {
        #expect(MarkdownBlockParser.parse("Run:\n```\nls -la") == [
            .paragraph("Run:"),
            .codeBlock(language: nil, code: "ls -la"),
        ])
    }

    @Test("bold text at line start is not a bullet; a run summary parses cleanly")
    func boldIsNotBullet() {
        let summary = AgentRunSummary(
            outcome: .done, title: "Done", headline: "All 1 sub-goal verified.", answer: nil,
            items: [AgentRunSummary.Item(index: 1, text: "Open Settings", status: .verified)],
            nextSteps: ["Nothing else is needed."]
        )
        #expect(MarkdownBlockParser.parse(summary.markdown) == [
            .paragraph("**Done.** All 1 sub-goal verified."),
            .orderedList(start: 1, items: ["Open Settings: verified."]),
            .paragraph("Next: Nothing else is needed."),
        ])
    }
}
