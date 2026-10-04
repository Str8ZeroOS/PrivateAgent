import SwiftUI
import AgentCore

public struct AgentModeView: View {
    @State private var viewModel = AgentModeViewModel()

    public init() {}

    public var body: some View {
        Form {
            Section("Goal") {
                TextField("What should PrivateAgent do?", text: $viewModel.goal, axis: .vertical)
                    .lineLimit(3...6)

                Button("Make Plan") {
                    Task { await viewModel.makePlan(appContext: "PrivateAgent") }
                }
                .disabled(viewModel.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

            if let errorMessage = viewModel.errorMessage {
                Section("Error") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Agent Mode")
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
    }
}
