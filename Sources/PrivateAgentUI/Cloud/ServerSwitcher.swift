import SwiftUI

/// Small menu under the chat title: switch between this iPhone and your saved servers.
struct ServerSwitcher: View {
    let onDeviceName: String?
    @AppStorage(CloudSettings.enabledKey) private var cloudEnabled: Bool = false
    @AppStorage(CloudSettings.selectedKey) private var selectedID: String = ""

    private var profiles: [CloudProfile] { CloudSettings.profiles }
    private var current: CloudProfile? {
        profiles.first(where: { $0.id.uuidString == selectedID }) ?? profiles.first
    }

    private var label: String {
        if cloudEnabled, let p = current {
            return p.name + (p.model.isEmpty ? "" : " \u{00B7} " + p.model)
        }
        return onDeviceName ?? "On this iPhone"
    }

    var body: some View {
        Menu {
            Button {
                cloudEnabled = false
            } label: {
                if !cloudEnabled {
                    Label("On this iPhone", systemImage: "checkmark")
                } else {
                    Text("On this iPhone")
                }
            }
            ForEach(profiles) { p in
                Button {
                    selectedID = p.id.uuidString
                    cloudEnabled = true
                } label: {
                    if cloudEnabled && p.id.uuidString == current?.id.uuidString {
                        Label(p.name, systemImage: "checkmark")
                    } else {
                        Text(p.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text(label).lineLimit(1)
                Image(systemName: "chevron.down")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}