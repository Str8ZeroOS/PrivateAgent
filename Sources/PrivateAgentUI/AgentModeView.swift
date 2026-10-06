import SwiftUI
import SwiftData
import AgentCore
import FlashMoEBridge

public struct AgentModeView: View {
    @Environment(PrivateAgentEngine.self) private var engine
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = AgentModeViewModel()
    @State private var isApprovalDialogPresented = false
    @State private var currentRunRecord: AgentRunRecord?

    public init() {}

    public var body: some View {
        Form {
            Section("Goal") {
                Picker("Planner", selection: $viewModel.planningMode) {
                    ForEach(AgentPlanningMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if viewModel.planningMode == .localModel && engine.state != .ready {
                    Text("Load a model before using local planning.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField("What should Str8ZeRO do?", text: $viewModel.goal, axis: .vertical)
                    .lineLimit(3...6)

                HStack {
                    Button("Preview Plan") {
                        Task {
                            await viewModel.makePlan(engine: engine, appContext: "PrivateAgent")
                            savePlanningRecord()
                        }
                    }
                    .disabled(isMakePlanDisabled || viewModel.isRunning)

                    Button(viewModel.isRunning ? "Running…" : "Run Agent") {
                        Task {
                            await runAgentAndSaveHistory()
                        }
                    }
                    .disabled(isMakePlanDisabled || viewModel.isRunning)

                    if viewModel.isRunning {
                        Button("Cancel", role: .destructive) {
                            Task { await viewModel.cancelAgent() }
                        }
                    }
                }
            }

            Section("Live State") {
                LabeledContent("Phase", value: viewModel.phase.title)
                LabeledContent("Workspace", value: viewModel.lastObservation?.appContext ?? "PrivateAgent.agentMode")
                LabeledContent("Source", value: viewModel.lastObservation?.source.rawValue ?? ObservationSource.privateAgentApp.rawValue)
                LabeledContent("Mac pairing", value: viewModel.bridgeHost.isEmpty ? "Not paired" : "\(viewModel.bridgeHost):\(viewModel.bridgePort)")
                LabeledContent("Loop step", value: "\(viewModel.loopSnapshot?.agentStepCount ?? 0) / \(AgentLoopLimits.default.maxAgentSteps)")
                if viewModel.isRunning {
                    ProgressView()
                }
                if let message = viewModel.loopSnapshot?.outcomeMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let progress = viewModel.loopSnapshot?.goalProgress, !progress.subGoals.isEmpty {
                Section("Sub-goals") {
                    ForEach(progress.subGoals) { subGoal in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(subGoal.text)
                            Text(subGoal.status.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if let detail = subGoal.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let answer = progress.finalAnswer, !answer.isEmpty {
                        LabeledContent("Final answer", value: answer)
                    }
                }
            }

            if let observation = viewModel.lastObservation, !observation.controls.isEmpty {
                Section("Observed Controls") {
                    ForEach(observation.controls) { control in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(control.label)
                            Text("\(control.id) · \(control.role.rawValue)\(control.isEnabled ? "" : " · disabled")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let observation = viewModel.lastObservation, !observation.visibleText.isEmpty {
                Section("Visible Text") {
                    ForEach(Array(observation.visibleText.prefix(12).enumerated()), id: \.offset) { _, text in
                        Text(text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                TextField("Host (PC/Mac IP)", text: $viewModel.bridgeHost)
                    .autocorrectionDisabled()
                TextField("Port", text: $viewModel.bridgePort)

                if let status = viewModel.bridgeConnection {
                    BridgeStatusRow(
                        title: status.title,
                        detail: status.detail,
                        hint: status.hint,
                        tone: tone(for: status.state)
                    )
                }

                if viewModel.bridgeConnection?.needsPairingCode == true || !viewModel.pairingCode.isEmpty {
                    TextField("6-digit pairing code", text: $viewModel.pairingCode)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.numberPad) // cross-platform-check: allow
                        #endif
                    Button("Pair") {
                        Task { await viewModel.pairBridge() }
                    }
                    .disabled(viewModel.isCheckingBridge || BridgeConnectionManager.normalizePairingCode(viewModel.pairingCode) == nil)
                }

                Button {
                    Task { await viewModel.checkBridgeHealth() }
                } label: {
                    HStack {
                        Text("Check Bridge")
                        if viewModel.isCheckingBridge {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(viewModel.isCheckingBridge)

                if viewModel.bridgeConnection?.redactedToken != nil {
                    Button("Forget Pairing", role: .destructive) {
                        Task { await viewModel.forgetBridgePairing() }
                    }
                    .disabled(viewModel.isCheckingBridge)
                }
            } header: {
                Text("Mac Bridge")
            } footer: {
                Text("Run python Bridge/mac_bridge_helper.py on your PC or Mac. It shows a 6-digit pairing code; Check Bridge asks for it once and keeps the token in the Keychain.")
            }

            Section {
                Text("Developer-device only. Not App Store safe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Host", text: $viewModel.wdaHost)
                    .autocorrectionDisabled()
                TextField("Port", text: $viewModel.wdaPort)

                if let status = viewModel.wdaConnection {
                    BridgeStatusRow(
                        title: status.title,
                        detail: status.detail,
                        hint: status.hint,
                        tone: tone(for: status.state)
                    )
                    if let sessionId = status.sessionId {
                        LabeledContent("Session", value: sessionId.count > 12 ? String(sessionId.prefix(12)) + "…" : sessionId)
                            .font(.caption)
                    }
                }

                Button {
                    Task { await viewModel.checkWDAStatus() }
                } label: {
                    HStack {
                        Text("Check WDA")
                        if viewModel.isCheckingWDA {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(viewModel.isCheckingWDA)

                if viewModel.wdaConnection?.kind == .direct, viewModel.wdaConnection?.sessionId != nil {
                    Button("New WDA Session") {
                        Task { await viewModel.resetWDASession() }
                    }
                    .disabled(viewModel.isCheckingWDA)
                }
            } header: {
                Text("WebDriverAgent")
            } footer: {
                Text("WebDriverAgentRunner on this iPhone listens on 127.0.0.1:8100. The Str8ZeRO adapter (Bridge/wda_adapter.py) on a computer uses port 8101. No token needed; the session is created automatically.")
            }

            Section("Allowed Modes") {
                ForEach(AutomationCapabilities.supportedModes) { capability in
                    Toggle(isOn: binding(for: capability.mode)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(capability.title)
                            Text(capability.notes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let plan = viewModel.plan {
                Section("Plan") {
                    LabeledContent("Summary", value: plan.summary)
                    LabeledContent("Risk", value: plan.risk.rawValue.capitalized)
                    LabeledContent("Approval", value: plan.requiresUserApproval ? "Required" : "Not required")

                    if let diagnostics = viewModel.plannerDiagnostics, diagnostics.usedRepair {
                        LabeledContent("JSON Repair", value: "\(diagnostics.repairAttempts) attempt(s)")
                    }

                    if !viewModel.isRunning {
                        Button(plan.requiresUserApproval ? "Approve and Run Once" : "Run Plan Once") {
                            if plan.requiresUserApproval {
                                isApprovalDialogPresented = true
                            } else {
                                Task { await runPlanAndSaveHistory() }
                            }
                        }
                    }
                }

                Section("Steps") {
                    ForEach(plan.steps) { step in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(actionTitle(step.action))
                                .font(.headline)
                            Text(step.rationale)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if step.requiresApproval || step.risk != .low {
                                Text("Risk \(step.risk.rawValue)\(step.requiresApproval ? " · approval required" : "")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if let record = viewModel.stepRecords.last(where: { $0.step.id == step.id }) {
                                Text(record.outcome.title)
                                    .font(.caption)
                                    .foregroundStyle(record.verification?.verified == true ? .green : .secondary)
                                if let verification = record.verification {
                                    Text(verification.message)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            if !viewModel.executionResults.isEmpty {
                Section("Results") {
                    ForEach(Array(viewModel.executionResults.enumerated()), id: \.offset) { _, result in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(result.status.rawValue.capitalized)
                                .font(.headline)
                            Text(result.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Section("Error") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Agent Mode")
        .workspaceSnapshot(
            .agentMode,
            extraVisibleText: viewModel.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? []
                : [viewModel.goal],
            traits: [
                "phase": viewModel.phase.title,
                "planner": viewModel.planningMode.rawValue
            ]
        )
        .onAppear {
            viewModel.reloadPairing()
            consumePendingPairing()
        }
        .onChange(of: AppRouter.shared.pendingBridgePairing) { _, _ in
            consumePendingPairing()
        }
        .toolbar {
            ToolbarItem {
                NavigationLink("History") {
                    AgentHistoryView()
                }
            }
        }
        .confirmationDialog(
            viewModel.pendingApproval == nil ? "Run this plan?" : "Approve this agent plan?",
            isPresented: Binding(
                get: { isApprovalDialogPresented || viewModel.pendingApproval != nil },
                set: { newValue in
                    isApprovalDialogPresented = newValue
                    if !newValue && viewModel.pendingApproval != nil {
                        Task { await viewModel.rejectPendingPlan() }
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(viewModel.pendingApproval == nil ? "Run Plan" : "Approve", role: .destructive) {
                Task {
                    if viewModel.pendingApproval != nil {
                        await viewModel.approvePendingPlan()
                    } else {
                        await runPlanAndSaveHistory()
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                if viewModel.pendingApproval != nil {
                    Task { await viewModel.rejectPendingPlan() }
                }
            }
        } message: {
            Text(viewModel.pendingApproval?.reason ?? "This plan requires approval because it may use external control, sensitive actions, or a higher-risk automation mode.")
        }
    }

    private func consumePendingPairing() {
        guard let pending = AppRouter.shared.pendingBridgePairing else { return }
        AppRouter.shared.pendingBridgePairing = nil
        Task { await viewModel.handlePendingPairing(pending) }
    }

    private func tone(for state: BridgeConnectionState) -> BridgeStatusRow.Tone {
        switch state {
        case .paired: return .good
        case .reachableUnpaired, .tokenInvalid, .pairingFailed: return .warning
        case .unreachable, .error: return .bad
        case .notConfigured: return .neutral
        }
    }

    private func tone(for state: WDAConnectionState) -> BridgeStatusRow.Tone {
        switch state {
        case .ready: return .good
        case .notReady, .unauthorized: return .warning
        case .unreachable, .sessionFailed, .error: return .bad
        case .notConfigured: return .neutral
        }
    }

    private var isMakePlanDisabled: Bool {
        let emptyGoal = viewModel.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let localModelUnavailable = viewModel.planningMode == .localModel && engine.state != .ready
        return emptyGoal || localModelUnavailable
    }

    private func runPlanAndSaveHistory() async {
        await viewModel.runPlan()
        updateExecutionHistory()
    }

    private func runAgentAndSaveHistory() async {
        await viewModel.runAgent(engine: engine, appContext: "PrivateAgent")
        savePlanningRecord()
        updateExecutionHistory()
    }

    private func savePlanningRecord() {
        guard let observation = viewModel.lastObservation else { return }
        let allowedModes = viewModel.allowedModes.map(\.rawValue)

        let record = AgentRunRecord(
            goal: viewModel.goal,
            planningMode: viewModel.planningMode.rawValue,
            allowedModesJSON: AgentRunRecordCoding.encode(allowedModes) ?? "[]",
            observationJSON: AgentRunRecordCoding.encode(observation) ?? "{}",
            planJSON: viewModel.plan.flatMap { AgentRunRecordCoding.encode($0) },
            diagnosticsJSON: viewModel.plannerDiagnostics.flatMap { AgentRunRecordCoding.encode($0) },
            loopSnapshotJSON: viewModel.loopSnapshot.flatMap { AgentRunRecordCoding.encode($0) },
            errorMessage: viewModel.errorMessage
        )

        modelContext.insert(record)
        currentRunRecord = record
        try? modelContext.save()
    }

    private func updateExecutionHistory() {
        guard let currentRunRecord else { return }
        currentRunRecord.executionResultsJSON = AgentRunRecordCoding.encode(viewModel.executionResults)
        currentRunRecord.loopSnapshotJSON = viewModel.loopSnapshot.flatMap { AgentRunRecordCoding.encode($0) }
        currentRunRecord.errorMessage = viewModel.errorMessage
        try? modelContext.save()
    }

    private func binding(for mode: AutomationMode) -> Binding<Bool> {
        Binding(
            get: { viewModel.allowedModes.contains(mode) },
            set: { isEnabled in
                if isEnabled {
                    if !viewModel.allowedModes.contains(mode) {
                        viewModel.allowedModes.append(mode)
                    }
                } else {
                    viewModel.allowedModes.removeAll { $0 == mode }
                }
            }
        )
    }

    private func actionTitle(_ action: AgentAction) -> String {
        switch action {
        case .answer:
            return "Answer"
        case .askUser:
            return "Ask User"
        case .openURL(let url):
            return "Open URL: \(url)"
        case .runShortcut(let name):
            return "Run Shortcut: \(name)"
        case .invokeAppIntent(let name):
            return "Invoke App Intent: \(name)"
        case .tap(let controlId):
            return "Tap: \(controlId)"
        case .type(let controlId, _):
            return "Type Into: \(controlId)"
        case .scroll(let direction):
            return "Scroll: \(direction.rawValue)"
        case .wait(let seconds):
            return "Wait: \(seconds)s"
        case .handoff(let handoff):
            return "Handoff: \(handoff.target.rawValue)"
        }
    }
}

/// Live connection status: colored title, reason, and a short hint.
struct BridgeStatusRow: View {
    enum Tone {
        case good, warning, bad, neutral
    }

    let title: String
    let detail: String
    let hint: String?
    let tone: Tone

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let hint, !hint.isEmpty {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch tone {
        case .good: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .bad: return "xmark.octagon.fill"
        case .neutral: return "questionmark.circle"
        }
    }

    private var color: Color {
        switch tone {
        case .good: return .green
        case .warning: return .orange
        case .bad: return .red
        case .neutral: return .secondary
        }
    }
}

#Preview {
    NavigationStack {
        AgentModeView()
            .environment(PrivateAgentEngine())
    }
    .modelContainer(for: [AgentRunRecord.self], inMemory: true)
}
