import SwiftUI
import AgentCore

struct SettingsView: View {
    @AppStorage("maxTokens") private var maxTokens: Double = 2048
    @AppStorage("temperature") private var temperature: Double = 0.7
    @AppStorage("defaultSystemPrompt") private var systemPrompt: String = "You are a helpful assistant."
    @AppStorage(AssistantStylePreferences.enabledKey) private var answerStyleEnabled: Bool = true
    @AppStorage(CloudSettings.enabledKey) private var cloudEnabled: Bool = false
    @AppStorage(CloudSettings.selectedKey) private var selectedID: String = ""
    @State private var profiles: [CloudProfile] = CloudSettings.profiles
    @AppStorage(MemoryStore.enabledKey) private var memoryEnabled: Bool = true
    @State private var memories: [MemoryEntry] = MemoryStore.entries
    @State private var newMemory: String = ""
    @State private var apiKeyDraft: String = ""
    @State private var keySaved: Bool = CloudSettings.apiKey != nil
    @State private var testResult: String = ""

    private enum ProfileField { case name, baseURL, model }

    private func profileBinding(_ field: ProfileField) -> Binding<String> {
        Binding(
            get: {
                guard let p = profiles.first(where: { $0.id.uuidString == selectedID }) else { return "" }
                switch field {
                case .name: return p.name
                case .baseURL: return p.baseURL
                case .model: return p.model
                }
            },
            set: { value in
                guard let i = profiles.firstIndex(where: { $0.id.uuidString == selectedID }) else { return }
                switch field {
                case .name: profiles[i].name = value
                case .baseURL: profiles[i].baseURL = value
                case .model: profiles[i].model = value
                }
                CloudSettings.saveProfiles(profiles)
                keySaved = CloudSettings.apiKey != nil
            }
        )
    }
    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ConnectionsView()
                } label: {
                    Label("Connections", systemImage: "network")
                }
            } footer: {
                Text("Choose where answers come from (this iPhone, NVIDIA, or your own server) and manage each one's API key.")
            }
            Section("Generation") {
                VStack(alignment: .leading) {
                    Text("Max Tokens: \(Int(maxTokens))")
                    Slider(value: $maxTokens, in: 128...4096, step: 128)
                }
                VStack(alignment: .leading) {
                    Text("Temperature: \(String(format: "%.1f", temperature))")
                    Slider(value: $temperature, in: 0...2, step: 0.1)
                }
            }
            Section("System Prompt") {
                TextEditor(text: $systemPrompt)
                    .frame(minHeight: 80)
            }
            Section {
                Toggle("Consistent answer style", isOn: $answerStyleEnabled)
            } header: {
                Text("Answer Style")
            } footer: {
                Text("Answers lead with the result, use numbered steps for things you need to do, and only say \"done\" when it was verified. Applies to the on-device model, NVIDIA cloud, and Agent Mode summaries.")
            }
            Section {
                Toggle("Use memory in chats", isOn: $memoryEnabled)
                ForEach(memories) { m in
                    Text(m.text)
                }
                .onDelete { offsets in
                    MemoryStore.remove(at: offsets)
                    memories = MemoryStore.entries
                }
                HStack {
                    TextField("Add something to remember", text: $newMemory)
                    Button("Add") {
                        MemoryStore.add(newMemory)
                        newMemory = ""
                        memories = MemoryStore.entries
                    }
                    .disabled(newMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !memories.isEmpty {
                    Button("Clear all memories", role: .destructive) {
                        MemoryStore.clear()
                        memories = []
                    }
                }
            } header: {
                Text("Memory")
            } footer: {
                Text("Say \"remember that ...\" in any chat, or add items here. Saved items are added to every conversation. With a cloud or private server on, they are sent to it with your messages. Never save passwords or API keys.")
            }
            Section("About") {
                LabeledContent("App", value: "Str8ZeRO")
                LabeledContent("Version", value: "0.1.0")
                Link("GitHub", destination: URL(string: "https://github.com")!)
            }
        }
        .navigationTitle("Settings")
        .workspaceSnapshot(
            .settings,
            extraVisibleText: testResult.isEmpty ? [] : [testResult],
            traits: [
                "cloudEnabled": cloudEnabled ? "true" : "false",
                "answerStyle": answerStyleEnabled ? "true" : "false",
                "keySaved": keySaved ? "true" : "false"
            ]
        )
        .onAppear {
            if CloudSettings.importKeyFromDocuments() { cloudEnabled = true }
            memories = MemoryStore.entries
            if !profiles.contains(where: { $0.id.uuidString == selectedID }) {
                selectedID = CloudSettings.selected.id.uuidString
            }
            keySaved = CloudSettings.apiKey != nil
        }
    }
}
