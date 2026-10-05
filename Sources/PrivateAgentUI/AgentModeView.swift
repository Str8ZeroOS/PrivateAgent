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

                TextField("What should PrivateAgent do?", text: $viewModel.goal, axis: .vertical)
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

            Section("Mac Bridge") {
                TextField("Host", text: $viewModel.bridgeHost)
                TextField("Port", text: $viewModel.bridgePort)
                SecureField("Token", text: $viewModel.bridgeToken)

                Button("Check Bridge") {
                    Task { await viewModel.checkBridgeHealth() }
                }

                if let bridgeStatus = viewModel.bridgeStatus {
                    Text(bridgeStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
        .onAppear {
            Task { _ = await InAppWorkspaceStore.shared.perform(.open(.agentMode)) }
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

#Preview {
    NavigationStack {
        AgentModeView()
            .environment(PrivateAgentEngine())
    }
    .modelContainer(for: [AgentRunRecord.self], inMemory: true)
}
