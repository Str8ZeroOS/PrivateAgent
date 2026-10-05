import Foundation

public protocol AgentPlanning: Sendable {
    func makePlan(for observation: AgentObservation, allowedModes: [AutomationMode]) async throws -> AgentPlan
}

public struct RuleBasedAgentPlanner: AgentPlanning {
    public init() {}

    public func makePlan(for observation: AgentObservation, allowedModes: [AutomationMode]) async throws -> AgentPlan {
        let trimmedGoal = observation.userGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else {
            return AgentPlan(
                summary: "Ask for a task before acting.",
                steps: [
                    AgentStep(
                        action: .askUser("What would you like PrivateAgent to do?"),
                        rationale: "The agent needs a concrete goal.",
                        target: "user",
                        expectedResult: "User provides a goal"
                    )
                ],
                requiresUserApproval: false,
                risk: .low
            )
        }

        if isExternalObservationSource(observation.source) {
            return externalObservationPlan(for: observation, allowedModes: allowedModes)
        }

        if let deepLinkPlan = deepLinkPlan(for: observation) {
            return deepLinkPlan
        }

        if let workspacePlan = inAppWorkspacePlan(for: observation, allowedModes: allowedModes) {
            return workspacePlan
        }

        if requiresExternalAutomation(observation: observation) {
            return externalHandoffPlan(allowedModes: allowedModes)
        }

        return AgentPlan(
            summary: "Handle the request inside PrivateAgent.",
            steps: [
                AgentStep(
                    action: .answer(trimmedGoal),
                    rationale: "The task can be handled by the local chat/model workspace without external app control.",
                    target: "privateAgent",
                    expectedResult: trimmedGoal
                )
            ],
            requiresUserApproval: false,
            risk: .low
        )
    }

    private func isExternalObservationSource(_ source: ObservationSource) -> Bool {
        switch source {
        case .macBridge, .iphoneMirroring, .webDriverAgent, .jailbreakBridge:
            return true
        case .privateAgentApp, .appIntent, .shortcuts, .userProvided:
            return false
        }
    }

    private func externalObservationPlan(for observation: AgentObservation, allowedModes _: [AutomationMode]) -> AgentPlan {
        if let control = matchingObservedControl(in: observation) {
            return AgentPlan(
                summary: "Use a control from the current Mac/WDA observation.",
                steps: [
                    AgentStep(
                        action: .tap(controlId: control.id),
                        rationale: "The live external observation includes this control.",
                        target: control.id,
                        risk: .medium,
                        requiresApproval: true,
                        expectedResult: control.label,
                        verification: .visibleTextContains(control.label)
                    )
                ],
                requiresUserApproval: true,
                risk: .medium
            )
        }

        if let text = quotedText(in: observation.userGoal),
           let field = observation.controls.first(where: { $0.role == .textField }) {
            return AgentPlan(
                summary: "Type into the observed field.",
                steps: [
                    AgentStep(
                        action: .type(controlId: field.id, text: text),
                        rationale: "The goal includes quoted text and the current observation has a text field.",
                        target: field.id,
                        risk: .medium,
                        requiresApproval: true,
                        expectedResult: text,
                        verification: .visibleTextContains(text)
                    )
                ],
                requiresUserApproval: true,
                risk: .medium
            )
        }

        if let url = ExternalGoalURL.inferred(from: observation.userGoal),
           InAppDeepLink.screen(from: url) == nil {
            return AgentPlan(
                summary: "Open a URL through the paired external adapter.",
                steps: [
                    AgentStep(
                        action: .openURL(url),
                        rationale: "No matching control is visible yet; open the inferred destination first.",
                        target: url,
                        risk: .medium,
                        requiresApproval: true,
                        expectedResult: url,
                        verification: .urlContains(url)
                    )
                ],
                requiresUserApproval: true,
                risk: .medium
            )
        }

        return AgentPlan(
            summary: "Ask for a visible external target.",
            steps: [
                AgentStep(
                    action: .askUser("No matching control is visible on the current Mac/WDA screen. Which control should I use?"),
                    rationale: "The observation is already external; handing off again would loop.",
                    target: "user",
                    expectedResult: "User identifies a visible control"
                )
            ]
        )
    }

    private func quotedText(in goal: String) -> String? {
        guard let start = goal.firstIndex(of: "\""),
              let end = goal[goal.index(after: start)...].firstIndex(of: "\"") else {
            return nil
        }
        let text = String(goal[goal.index(after: start)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func externalHandoffPlan(allowedModes: [AutomationMode]) -> AgentPlan {
        let target = bestExternalMode(from: allowedModes)
        return AgentPlan(
            summary: "Prepare an external automation handoff.",
            steps: [
                AgentStep(
                    action: .handoff(AgentHandoff(target: target, reason: "This task appears to require reading or controlling another app.")),
                    rationale: "Normal iOS apps cannot inspect and control arbitrary third-party apps like Android Accessibility Services.",
                    target: target.rawValue,
                    risk: target == .jailbreak ? .high : .medium,
                    requiresApproval: true,
                    expectedResult: "External automation mode accepted the handoff"
                )
            ],
            requiresUserApproval: true,
            risk: target == .jailbreak ? .high : .medium
        )
    }

    private func requiresExternalAutomation(observation: AgentObservation) -> Bool {
        let goal = observation.userGoal.lowercased()
        if matchingObservedControl(in: observation) != nil {
            return false
        }
        let externalSignals = [
            "swipe", "scroll", "open app", "instagram", "youtube", "telegram", "chrome", "safari",
            "control my phone", "use my phone", "iphone settings", "ios settings", "system settings",
            "settings app", "iphone mirroring"
        ]
        if externalSignals.contains(where: { goal.contains($0) }) {
            return true
        }
        if goal.contains("tap") && matchingObservedControl(in: observation) == nil {
            return true
        }
        return false
    }

    private func deepLinkPlan(for observation: AgentObservation) -> AgentPlan? {
        guard let screen = InAppDeepLink.screen(inGoal: observation.userGoal) else {
            return nil
        }
        let url = InAppDeepLink.url(for: screen).absoluteString
        return AgentPlan(
            summary: "Open PrivateAgent \(screen.rawValue).",
            steps: [
                AgentStep(
                    action: .openURL(url),
                    rationale: "The goal is a first-party PrivateAgent deep link.",
                    target: url,
                    expectedResult: screen.rawValue,
                    verification: .appContextContains(screen.rawValue)
                )
            ]
        )
    }

    private func inAppWorkspacePlan(for observation: AgentObservation, allowedModes: [AutomationMode]) -> AgentPlan? {
        if let control = matchingObservedControl(in: observation) {
            return AgentPlan(
                summary: "Use a PrivateAgent workspace control.",
                steps: [
                    AgentStep(
                        action: .tap(controlId: control.id),
                        rationale: "The requested control is part of PrivateAgent's own UI.",
                        target: control.id,
                        expectedResult: control.label,
                        verification: .visibleTextContains(control.label)
                    )
                ]
            )
        }

        if let intent = FirstPartyAppIntents.matchingGoal(observation.userGoal) {
            let action: AgentAction = allowedModes.contains(.appIntents)
                ? .invokeAppIntent(intent.name)
                : .tap(controlId: intent.controlId ?? "nav.agentMode")
            return AgentPlan(
                summary: "Handle the request inside PrivateAgent.",
                steps: [
                    AgentStep(
                        action: action,
                        rationale: "This is a first-party PrivateAgent workspace action, not third-party UI control.",
                        target: intent.controlId ?? intent.name,
                        expectedResult: intent.summary,
                        verification: .appContextContains(intent.screen?.rawValue ?? "PrivateAgent")
                    )
                ]
            )
        }

        return nil
    }

    private func matchingObservedControl(in observation: AgentObservation) -> AgentControl? {
        let goal = observation.userGoal.lowercased()
        let controls: [AgentControl]
        if isExternalObservationSource(observation.source) {
            controls = observation.controls
        } else {
            controls = observation.controls.isEmpty ? InAppWorkspace.allControls() : observation.controls
        }
        return controls.first { control in
            let label = control.label.lowercased()
            let id = control.id.lowercased()
            return (!label.isEmpty && goal.contains(label)) || (!id.isEmpty && goal.contains(id))
        }
    }

    private func bestExternalMode(from allowedModes: [AutomationMode]) -> AutomationMode {
        if allowedModes.contains(.macAssisted) { return .macAssisted }
        if allowedModes.contains(.webDriverAgent) { return .webDriverAgent }
        if allowedModes.contains(.shortcuts) { return .shortcuts }
        if allowedModes.contains(.appIntents) { return .appIntents }
        if allowedModes.contains(.jailbreak) { return .jailbreak }
        return .inApp
    }
}
