import SwiftUI
import SwiftData

public struct AgentHistoryView: View {
    @Query(sort: \AgentRunRecord.createdAt, order: .reverse) private var records: [AgentRunRecord]

    public init() {}

    public var body: some View {
        List {
            if records.isEmpty {
                ContentUnavailableView("No Agent Runs", systemImage: "clock", description: Text("Plans and execution results will appear here after you use Agent Mode."))
            } else {
                ForEach(records) { record in
                    NavigationLink {
                        AgentRunRecordDetailView(record: record)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.goal)
                                .font(.headline)
                                .lineLimit(2)
                            Text(record.createdAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(record.planningMode)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Agent History")
    }
}

private struct AgentRunRecordDetailView: View {
    let record: AgentRunRecord

    var body: some View {
        List {
            Section("Summary") {
                LabeledContent("Goal", value: record.goal)
                LabeledContent("Planner", value: record.planningMode)
                LabeledContent("Created", value: record.createdAt.formatted())
            }

            if let errorMessage = record.errorMessage {
                Section("Error") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            Section("Allowed Modes") {
                Text(record.allowedModesJSON)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }

            Section("Observation") {
                Text(record.observationJSON)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }

            if let planJSON = record.planJSON {
                Section("Plan") {
                    Text(planJSON)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            if let diagnosticsJSON = record.diagnosticsJSON {
                Section("Diagnostics") {
                    Text(diagnosticsJSON)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            if let executionResultsJSON = record.executionResultsJSON {
                Section("Execution Results") {
                    Text(executionResultsJSON)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Agent Run")
    }
}

#Preview {
    NavigationStack {
        AgentHistoryView()
    }
    .modelContainer(for: [AgentRunRecord.self], inMemory: true)
}
