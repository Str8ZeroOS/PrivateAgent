import Testing
import AgentCore
import ModelPack
@testable import PrivateAgentUI

@Suite("Chat providers apply the answer style")
struct ChatStylePromptTests {
    @Test("on-device ChatML prompt carries the style guide in the system block")
    func onDevicePrompt() {
        let messages = ChatViewModel.onDeviceMessages(
            systemPrompt: "/no_think\nYou are a helpful assistant.",
            userText: "How do I clear Safari history?",
            styleEnabled: true
        )
        #expect(messages.map(\.role) == ["system", "user"])
        let prompt = PromptCompiler.compile(messages: messages, addGenerationPrompt: true)
        #expect(prompt.hasPrefix("<|im_start|>system\n/no_think\nYou are a helpful assistant.\n\n\(AssistantStyleGuide.marker)"))
        #expect(prompt.contains("<|im_start|>user\nHow do I clear Safari history?<|im_end|>"))
        #expect(prompt.hasSuffix("<|im_start|>assistant\n"))
    }

    @Test("NVIDIA cloud messages carry the same style guide and drop /no_think")
    func cloudMessages() {
        let messages = ChatViewModel.cloudMessages(
            systemPrompt: "/no_think\nYou are a helpful assistant.",
            history: [AssistantChatTurn(role: "user", content: "hi"), AssistantChatTurn(role: "assistant", content: "Hello.")],
            userText: "How do I clear Safari history?",
            styleEnabled: true
        )
        #expect(messages.map(\.role) == ["system", "user", "assistant", "user"])
        #expect(messages[0].content == "You are a helpful assistant.\n\n" + AssistantStyleGuide.prompt)
        #expect(messages.last?.content == "How do I clear Safari history?")
    }

    @Test("both providers send identical style text")
    func sameGuide() {
        let device = ChatViewModel.onDeviceMessages(systemPrompt: "Base", userText: "q", styleEnabled: true)[0].content
        let cloud = ChatViewModel.cloudMessages(systemPrompt: "Base", history: [], userText: "q", styleEnabled: true)[0].content
        #expect(device == cloud)
    }

    @Test("toggle off sends only the user's system prompt to both providers")
    func disabled() {
        let device = ChatViewModel.onDeviceMessages(systemPrompt: "Base", userText: "q", styleEnabled: false)
        let cloud = ChatViewModel.cloudMessages(systemPrompt: "Base", history: [], userText: "q", styleEnabled: false)
        #expect(device[0].content == "Base")
        #expect(cloud[0].content == "Base")
    }
}
