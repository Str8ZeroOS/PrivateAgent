import SwiftUI
import AgentCore

struct SettingsView: View {
    @AppStorage("maxTokens") private var maxTokens: Double = 2048
    @AppStorage("temperature") private var temperature: Double = 0.7
    @AppStorage("defaultSystemPrompt") private var systemPrompt: String = "You are a helpful assistant."
    @AppStorage(CloudSettings.enabledKey) private var cloudEnabled: Bool = false
    @AppStorage(CloudSettings.modelKey) private var cloudModel: String = CloudSettings.defaultModel
    @State private var apiKeyDraft: String = ""
    @State private var keySaved: Bool = CloudSettings.apiKey != nil
    @State private var testResult: String = ""

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
                Toggle("Use NVIDIA cloud", isOn: $cloudEnabled)
                SecureField("NVIDIA API key (nvapi-...)", text: $apiKeyDraft)
                    .autocorrectionDisabled()
                Button("Save key") {
                    CloudSettings.setAPIKey(apiKeyDraft)
                    keySaved = !apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty
                    apiKeyDraft = ""
                }
                .disabled(apiKeyDraft.isEmpty)
                TextField("Model", text: $cloudModel)
                    .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never) // cross-platform-check: allow
                #endif
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
                Text("Cloud (NVIDIA)")
            } footer: {
                Text("When on, your messages are sent to NVIDIA's servers. Turn it off to stay fully offline.")
            }
            Section("About") {
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
                "keySaved": keySaved ? "true" : "false"
            ]
        )
        .onAppear {
            if CloudSettings.importKeyFromDocuments() { cloudEnabled = true }
            keySaved = CloudSettings.apiKey != nil
        }
    }
}
