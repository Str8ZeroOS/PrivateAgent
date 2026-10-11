import SwiftUI
import WebKit

#if os(iOS)
struct BrowserWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#elseif os(macOS)
struct BrowserWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif

/// The Assistant tab: give it a goal on the web and watch it work in a real browser.
struct AssistantView: View {
    @State private var agent = BrowserAgent()
    @State private var goal: String = ""
    @AppStorage(CloudSettings.selectedKey) private var selectedID: String = ""

    private var source: CloudProfile { CloudSettings.selected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 6) {
                    Image(systemName: "network").foregroundStyle(.secondary)
                    Text("\(source.name) \u{00B7} \(source.model.isEmpty ? CloudSettings.defaultModel : source.model)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 10) {
                    TextField("What should I do on the web?", text: $goal, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                    if agent.isRunning {
                        Button(role: .destructive) {
                            agent.stop()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            agent.start(goal: goal.trimmingCharacters(in: .whitespacesAndNewlines))
                        } label: {
                            Label("Start", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                BrowserWebView(webView: agent.session.webView)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))

                if let request = agent.pendingApproval {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Needs your approval", systemImage: "hand.raised.fill")
                            .font(.headline)
                        Text(request.title)
                        Text(request.detail).font(.footnote).foregroundStyle(.secondary)
                        HStack {
                            Button("Approve") { agent.resolveApproval(true) }
                                .buttonStyle(.borderedProminent)
                            Button("Decline", role: .destructive) { agent.resolveApproval(false) }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding()
                    .background(.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                }

                if !agent.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Steps").font(.headline)
                        ForEach(agent.steps) { step in
                            Label(step.text, systemImage: step.icon)
                                .font(.footnote)
                        }
                    }
                }

                if let answer = agent.finalAnswer {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Result").font(.headline)
                        Text(answer).textSelection(.enabled)
                        Button {
                            BrowserSession.copyToClipboard(answer)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                    .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }

                NavigationLink {
                    AgentModeView()
                } label: {
                    Label("Phone control (advanced)", systemImage: "gearshape.2")
                }

                Text("The assistant reads each page and sends its text to \(source.name) to decide the next step. It starts every run with no saved logins, never types passwords or card numbers, and asks you before submitting or buying anything.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("Assistant")
    }
}