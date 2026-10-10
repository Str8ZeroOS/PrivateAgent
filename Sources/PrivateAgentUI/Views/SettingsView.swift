import SwiftUI
import AgentCore

struct SettingsView: View {
    @AppStorage("maxTokens") private var maxTokens: Double = 2048
    @AppStorage("temperature") private var temperature: Double = 0.7
    @AppStorage("defaultSystemPrompt") private var systemPrompt: String = "You are a helpful assistant."
    @AppStorage(AssistantStylePreferences.enabledKey) private var answerStyleEnabled: Bool = true
    @AppStorage(CloudSettings.enabledKey) private var cloudEnabled: Bool = false
    @AppStorage(CloudSettings.modelKey) private var cloudModel: String = CloudSettings.defaultModel
    @AppStorage(CloudSettings.baseURLKey) private var cloudBaseURL: String = CloudSettings.defaultBaseURL
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
                TextField("Server URL (ends in /v1)", text: $cloudBaseURL)
                    .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never) // cross-platform-check: allow
                    .keyboardType(.URL) // cross-platform-check: allow
                #endif
                TextField("Model", text: $cloudModel)
                    .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never) // cross-platform-check: allow
                #endif
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
            keySaved = CloudSettings.apiKey != nil
        }
    }
}
