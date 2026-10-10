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
                Toggle("Use cloud / private server", isOn: $cloudEnabled)
                SecureField("API key (optional for your own server)", text: $apiKeyDraft)
                    .autocorrectionDisabled()
                Button("Save key") {
                    CloudSettings.setAPIKey(apiKeyDraft)
                    keySaved = !apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty
                    apiKeyDraft = ""
                }
                .disabled(apiKeyDraft.isEmpty)
                Picker("Server", selection: $selectedID) {
                    ForEach(profiles) { p in
                        Text(p.name).tag(p.id.uuidString)
                    }
                }
                .onChange(of: selectedID) {
                    keySaved = CloudSettings.apiKey != nil
                    testResult = ""
                }
                TextField("Name", text: profileBinding(.name))
                TextField("Server URL (ends in /v1)", text: profileBinding(.baseURL))
                    .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never) // cross-platform-check: allow
                    .keyboardType(.URL) // cross-platform-check: allow
                #endif
                TextField("Model", text: profileBinding(.model))
                    .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never) // cross-platform-check: allow
                #endif
                Button("Add another server") {
                    let p = CloudProfile(name: "New server", baseURL: "http://", model: "")
                    profiles.append(p)
                    CloudSettings.saveProfiles(profiles)
                    selectedID = p.id.uuidString
                }
                if profiles.count > 1 {
                    Button("Delete this server", role: .destructive) {
                        profiles.removeAll { $0.id.uuidString == selectedID }
                        CloudSettings.saveProfiles(profiles)
                        selectedID = profiles[0].id.uuidString
                    }
                }

                if !keySaved {
                    Button("Test connection") {
                        testResult = "Testing..."
                        let m = CloudSettings.model
                        Task {
                            let r = await NVIDIAClient.ping(model: m, apiKey: CloudSettings.apiKey ?? "")
                            testResult = "\(m): \(r)"
                        }
                    }
                    if !testResult.isEmpty {
                        Text(testResult).font(.footnote)
                    }
                }
                if keySaved {
                    Text("A key is saved in the Keychain.")
                        .foregroundStyle(.secondary)
                    Text("Key fingerprint: \(CloudSettings.fingerprint ?? "none")")
                        .font(.footnote.monospaced())
                    Button("Test key now") {
                        testResult = "Testing..."
                        let m = CloudSettings.model
                        let k = CloudSettings.apiKey ?? ""
                        Task {
                            let r = await NVIDIAClient.ping(model: m, apiKey: k)
                            testResult = "\(m): \(r)"
                        }
                    }
                    if !testResult.isEmpty {
                        Text(testResult).font(.footnote)
                    }
                    Button("Remove saved key", role: .destructive) {
                        CloudSettings.setAPIKey("")
                        keySaved = false
                        cloudEnabled = false
                    }
                }
            } header: {
                Text("Cloud / private server")
            } footer: {
                Text("When on, your messages go to the server URL above (NVIDIA by default, or your own PC). Turn it off to stay fully on-device.")
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
