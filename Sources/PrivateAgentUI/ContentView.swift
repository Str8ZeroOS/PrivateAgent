import SwiftUI
import SwiftData
import AgentCore
import FlashMoEBridge

public struct ContentView: View {
    @State private var engine = PrivateAgentEngine()
    @State private var path = NavigationPath()
    @State private var router = AppRouter.shared
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        @Bindable var router = router
        NavigationStack(path: $path) {
            ConversationListView(path: $path)
                .navigationDestination(for: UUID.self) { conversationId in
                    ChatView(conversationId: conversationId)
                }
                .toolbar {
                    ToolbarItem {
                        Button("Agent") {
                            router.open(.agentMode)
                        }
                    }
                }
        }
        .sheet(isPresented: $router.isAgentModePresented) {
            NavigationStack {
                AgentModeView()
                    .toolbar {
                        ToolbarItem {
                            Button("Done") {
                                router.isAgentModePresented = false
                            }
                        }
                    }
            }
        }
        .sheet(isPresented: $router.isModelsPresented) {
            NavigationStack {
                ModelManagerView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { router.isModelsPresented = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $router.isSettingsPresented) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { router.isSettingsPresented = false }
                        }
                    }
            }
        }
        .environment(engine)
        .environment(router)
        .modelContainer(for: [Conversation.self, Message.self, AgentRunRecord.self])
        .onOpenURL { url in
            router.open(url: url)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background && engine.state == .generating {
                print("[APP] entering background while generating — cancelling to avoid GPU error")
                engine.cancel()
            }
        }
    }
}
