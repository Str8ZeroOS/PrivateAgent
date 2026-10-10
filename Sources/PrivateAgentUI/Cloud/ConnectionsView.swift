import SwiftUI

/// One place for every source of answers: this iPhone, NVIDIA, your own server.
/// Each connection has its own card with its own API key, model and Test button.
struct ConnectionsView: View {
    @AppStorage(CloudSettings.enabledKey) private var cloudEnabled: Bool = false
    @AppStorage(CloudSettings.selectedKey) private var selectedID: String = ""
    @State private var profiles: [CloudProfile] = CloudSettings.profiles

    private var activeID: String? {
        guard cloudEnabled else { return nil }
        return (profiles.first(where: { $0.id.uuidString == selectedID }) ?? profiles.first)?.id.uuidString
    }

    var body: some View {
        List {
            Section {
                Button {
                    cloudEnabled = false
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "iphone").frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("This iPhone").foregroundStyle(.primary)
                            Text("Runs the downloaded model offline. Nothing leaves the phone.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !cloudEnabled {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                        }
                    }
                }
                ForEach(profiles) { p in
                    NavigationLink {
                        ConnectionDetailView(profileID: p.id) { profiles = CloudSettings.profiles }
                    } label: {
                        ConnectionRow(profile: p, isActive: activeID == p.id.uuidString)
                    }
                }
            } header: {
                Text("Where answers come from")
            } footer: {
                Text("Tap a connection to set it up. The checkmark shows what chat is using right now. You can switch any time from the menu under a chat's title.")
            }
            Section {
                Button {
                    let p = CloudProfile(name: "New connection", baseURL: "http://", model: "")
                    var list = CloudSettings.profiles
                    list.append(p)
                    CloudSettings.saveProfiles(list)
                    profiles = list
                } label: {
                    Label("Add connection", systemImage: "plus.circle")
                }
            }
        }
        .navigationTitle("Connections")
        .onAppear { profiles = CloudSettings.profiles }
    }
}

private struct ConnectionRow: View {
    let profile: CloudProfile
    let isActive: Bool

    private var status: (text: String, color: Color) {
        if CloudSettings.isNVIDIAURL(profile.baseURL) && CloudSettings.apiKey(for: profile) == nil {
            return ("Needs an API key", .orange)
        }
        if let ok = UserDefaults.standard.object(forKey: "connOK:" + profile.id.uuidString) as? Bool {
            return ok ? ("Working", .green) : ("Last test failed", .red)
        }
        return ("Not tested", .gray)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: CloudSettings.isNVIDIAURL(profile.baseURL) ? "cloud" : "desktopcomputer")
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                HStack(spacing: 6) {
                    Circle().fill(status.color).frame(width: 8, height: 8)
                    Text(status.text).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isActive {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
            }
        }
    }
}

struct ConnectionDetailView: View {
    let profileID: UUID
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage(CloudSettings.enabledKey) private var cloudEnabled: Bool = false
    @AppStorage(CloudSettings.selectedKey) private var selectedID: String = ""
    @State private var profile: CloudProfile
    @State private var keyDraft: String = ""
    @State private var fingerprint: String?
    @State private var testResult: String = ""
    @State private var testing: Bool = false

    init(profileID: UUID, onChange: @escaping () -> Void) {
        self.profileID = profileID
        self.onChange = onChange
        let p = CloudSettings.profiles.first(where: { $0.id == profileID })
            ?? CloudProfile(name: "", baseURL: "", model: "")
        _profile = State(initialValue: p)
        _fingerprint = State(initialValue: CloudSettings.fingerprint(for: p))
    }

    private var isNVIDIA: Bool { CloudSettings.isNVIDIAURL(profile.baseURL) }
    private var isInUse: Bool { cloudEnabled && selectedID == profile.id.uuidString }

    var body: some View {
        Form {
            Section("Use it") {
                if isInUse {
                    Label("Chat is using this connection", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Use this for chat") {
                        selectedID = profile.id.uuidString
                        cloudEnabled = true
                    }
                }
            }
            Section("Connection") {
                TextField("Name", text: $profile.name)
                TextField("Server URL (ends in /v1)", text: $profile.baseURL)
                    .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never) // cross-platform-check: allow
                    .keyboardType(.URL) // cross-platform-check: allow
                #endif
                TextField("Model", text: $profile.model)
                    .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never) // cross-platform-check: allow
                #endif
            }
            Section {
                if let fp = fingerprint {
                    Label("Key saved", systemImage: "key.fill")
                    Text("Fingerprint \(fp)")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }
                SecureField(fingerprint == nil ? "Paste API key" : "Paste a new key to replace it", text: $keyDraft)
                    .autocorrectionDisabled()
                Button("Save key") {
                    CloudSettings.setAPIKey(keyDraft, for: profile)
                    keyDraft = ""
                    fingerprint = CloudSettings.fingerprint(for: profile)
                    testResult = ""
                    onChange()
                }
                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                if fingerprint != nil {
                    Button("Remove key", role: .destructive) {
                        CloudSettings.setAPIKey("", for: profile)
                        fingerprint = nil
                        onChange()
                    }
                }
            } header: {
                Text("API key")
            } footer: {
                Text(isNVIDIA
                     ? "Required for NVIDIA. Stored in the iPhone Keychain, never in the app or logs."
                     : "Optional for your own server. Stored in the iPhone Keychain for this address only.")
            }
            Section("Check") {
                Button {
                    runTest()
                } label: {
                    if testing { ProgressView() } else { Text("Test connection") }
                }
                .disabled(testing)
                if !testResult.isEmpty {
                    Text(testResult).font(.footnote)
                }
            }
            Section {
                Button("Delete this connection", role: .destructive) { delete() }
                    .disabled(CloudSettings.profiles.count <= 1)
            }
        }
        .navigationTitle(profile.name.isEmpty ? "Connection" : profile.name)
        .onChange(of: profile) { persist() }
    }

    private func persist() {
        var list = CloudSettings.profiles
        if let i = list.firstIndex(where: { $0.id == profile.id }) {
            list[i] = profile
            CloudSettings.saveProfiles(list)
        }
        fingerprint = CloudSettings.fingerprint(for: profile)
        onChange()
    }

    private func runTest() {
        testing = true
        testResult = ""
        let p = profile
        Task {
            let raw = await NVIDIAClient.ping(
                model: p.model.isEmpty ? CloudSettings.defaultModel : p.model,
                apiKey: CloudSettings.apiKey(for: p) ?? "",
                baseURL: p.baseURL
            )
            let ok = raw.hasPrefix("OK")
            switch raw {
            case _ where ok: testResult = "Working. The server answered."
            case "HTTP 401", "HTTP 403": testResult = "The server refused the key. Paste it again above."
            case "HTTP 404": testResult = "Server found, but the URL or model name is wrong."
            default: testResult = raw
            }
            UserDefaults.standard.set(ok, forKey: "connOK:" + p.id.uuidString)
            testing = false
            onChange()
        }
    }

    private func delete() {
        var list = CloudSettings.profiles
        list.removeAll { $0.id == profile.id }
        guard !list.isEmpty else { return }
        CloudSettings.saveProfiles(list)
        if selectedID == profile.id.uuidString { selectedID = list[0].id.uuidString }
        onChange()
        dismiss()
    }
}