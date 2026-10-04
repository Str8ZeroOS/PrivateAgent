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

                Button("Make Plan") {
                    Task {
                        await viewModel.makePlan(engine: engine, appContext: "PrivateAgent")
                        savePlanningRecord()
                    }
                }
                .disabled(isMakePlanDisabled)
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

                    Button(plan.requiresUserApproval ? "Approve and Run Plan" : "Run Plan") {
                        if plan.requiresUserApproval {
                            isApprovalDialogPresented = true
                        } else {
                            Task { await runPlanAndSaveHistory() }
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
        .confirmationDialog(
            "Run this plan?",
            isPresented: $isApprovalDialogPresented,
            titleVisibility: .visible
        ) {
            Button("Run Plan", role: .destructive) {
                Task { await runPlanAndSaveHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This plan requires approval because it may use external control, sensitive actions, or a higher-risk automation mode.")
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

    private func savePlanningRecord() {
        guard let observation = viewModel.lastObservation else { return }

        let record = AgentRunRecord(
            goal: viewModel.goal,
            planningMode: viewModel.planningMode.rawValue,
            allowedModes: viewModel.allowedModes.map(\.rawValue),
            observationJSON: AgentRunRecordCoding.encode(observation) ?? "{}",
            planJSON: viewModel.plan.flatMap { AgentRunRecordCoding.encode($0) },
            diagnosticsJSON: viewModel.plannerDiagnostics.flatMap { AgentRunRecordCoding.encode($0) },
            errorMessage: viewModel.errorMessage
        )

        modelContext.insert(record)
        currentRunRecord = record
        try? modelContext.save()
    }

    private func updateExecutionHistory() {
        guard let currentRunRecord else { return }
        currentRunRecord.executionResultsJSON = AgentRunRecordCoding.encode(viewModel.executionResults)
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
