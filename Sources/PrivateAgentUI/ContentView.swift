import SwiftUI
import SwiftData
import FlashMoEBridge

public struct ContentView: View {
    @State private var engine = PrivateAgentEngine()
    @State private var path = NavigationPath()
    @State private var isAgentModePresented = false
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        NavigationStack(path: $path) {
            ConversationListView(path: $path)
                .navigationDestination(for: UUID.self) { conversationId in
                    ChatView(conversationId: conversationId)
                }
                .toolbar {
                    ToolbarItem {
                        Button("Agent") {
                            isAgentModePresented = true
                        }
                    }
                }
        }
        .sheet(isPresented: $isAgentModePresented) {
            NavigationStack {
                AgentModeView()
                    .toolbar {
                        ToolbarItem {
                            Button("Done") {
                                isAgentModePresented = false
                            }
                        }
                    }
            }
        }
        .environment(engine)
        .modelContainer(for: [Conversation.self, Message.self, AgentRunRecord.self])
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background && engine.state == .generating {
                print("[APP] entering background while generating — cancelling to avoid GPU error")
                engine.cancel()
            }
        }
    }
}
