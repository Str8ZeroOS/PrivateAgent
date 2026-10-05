import SwiftUI
import SwiftData
import AgentCore

struct ConversationListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    @State private var searchText = ""
    @Binding var path: NavigationPath

    var filteredConversations: [Conversation] {
        if searchText.isEmpty {
            return conversations
        }
        return conversations.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        @Bindable var router = router
        List {
            ForEach(filteredConversations) { conversation in
                NavigationLink(value: conversation.id) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(conversation.title)
                            .font(.headline)
                        Text(conversation.updatedAt.formatted(.relative(presentation: .named)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .onDelete(perform: deleteConversations)
        }
        .searchable(text: $searchText, prompt: "Search conversations")
        .navigationTitle("Str8ZeRO")
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) { // cross-platform-check: allow
                Button {
                    newConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
            ToolbarItem(placement: .topBarTrailing) { // cross-platform-check: allow
                Button {
                    router.open(.models)
                } label: {
                    Image(systemName: "square.grid.2x2")
                }
            }
            ToolbarItem(placement: .topBarTrailing) { // cross-platform-check: allow
                Button {
                    router.open(.settings)
                } label: {
                    Image(systemName: "gear")
                }
            }
            ToolbarItem(placement: .topBarLeading) { // cross-platform-check: allow
                EditButton()
            }
            #else
            ToolbarItem(placement: .automatic) {
                Button {
                    newConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    router.open(.models)
                } label: {
                    Image(systemName: "square.grid.2x2")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    router.open(.settings)
                } label: {
                    Image(systemName: "gear")
                }
            }
            #endif
        }
        .onChange(of: router.startChatRequested) { _, requested in
            guard requested else { return }
            router.startChatRequested = false
            newConversation()
        }
        .workspaceSnapshot(
            .chats,
            extraVisibleText: searchText.isEmpty ? [] : [searchText],
            traits: searchText.isEmpty ? [:] : ["search": searchText]
        )
    }

    private func newConversation() {
        let convo = Conversation()
        modelContext.insert(convo)
        try? modelContext.save()
        path.append(convo.id)
    }

    private func deleteConversations(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(filteredConversations[index])
        }
        try? modelContext.save()
    }
}
