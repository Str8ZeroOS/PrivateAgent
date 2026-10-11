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
        TabView {
            NavigationStack(path: $path) {
                ConversationListView(path: $path)
                    .navigationDestination(for: UUID.self) { conversationId in
                        ChatView(conversationId: conversationId)
                    }
            }
            .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }

            NavigationStack {
                AssistantView()
            }
            .tabItem { Label("Assistant", systemImage: "sparkles") }

            NavigationStack {
                ConnectionsView()
            }
            .tabItem { Label("Connections", systemImage: "network") }
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
