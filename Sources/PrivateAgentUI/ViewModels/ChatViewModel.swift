import Foundation
import SwiftData
import Observation
import FlashMoEBridge
import ModelPack
import ModelHub
import AgentCore

@MainActor
@Observable
final class ChatViewModel {
    let conversationId: UUID
    private let modelContext: ModelContext
    private let engine: PrivateAgentEngine

    var inputText: String = ""
    var isGenerating: Bool = false
    var streamingText: String = ""
    var currentStats: String = ""
    /// True when cloud chat needs an API key (missing or rejected). The chat screen shows a prompt.
    var needsCloudKey: Bool = false

    private(set) var conversation: Conversation?
    private var generationTask: Task<Void, Never>?
    private var lastBatchTime: Date = .distantPast

    private var needsReset = true

    init(conversationId: UUID, modelContext: ModelContext, engine: PrivateAgentEngine) {
        self.conversationId = conversationId
        self.modelContext = modelContext
        self.engine = engine
        loadConversation()
    }

    private func loadConversation() {
        let id = conversationId
        let descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.id == id }
        )
        conversation = try? modelContext.fetch(descriptor).first
    }

    var sortedMessages: [Message] {
        (conversation?.messages ?? []).sorted { $0.ordinal < $1.ordinal }
    }

    func sendMessage() {
        guard !inputText.isEmpty, !isGenerating else { return }
        guard let conversation else { return }

        // Optional cloud backend (NVIDIA). Skips the on-device engine entirely.
        _ = CloudSettings.importKeyFromDocuments()
        if CloudSettings.isEnabled && CloudSettings.usesNVIDIA && CloudSettings.apiKey == nil {
            needsCloudKey = true
            return
        }
        if CloudSettings.isActive {
            sendCloudMessage(conversation: conversation)
            return
        }

        // Auto-load model if engine isn't ready
        if engine.state == .idle {
            print("[CHAT] Engine idle, auto-loading model...")
            Task {
                await autoLoadModel()
                print("[CHAT] After autoLoad, engine state: \(engine.state)")
                if engine.state == .ready {
                    sendMessageInternal(conversation: conversation)
                }
            }
            return
        }
        if engine.state != .ready {
            print("[CHAT] Engine not ready, state: \(engine.state)")
            currentStats = "Engine not ready"
            return
        }

        sendMessageInternal(conversation: conversation)
    }

    private func autoLoadModel() async {
        print("[CHAT] autoLoadModel: scanning for downloaded models...")
        let storage = ModelStorage()
        let models = (try? await storage.listModels()) ?? []
        print("[CHAT] Found \(models.count) model(s): \(models.map { $0.lastPathComponent })")

        let selectedId = UserDefaults.standard.string(forKey: "selectedModelId") ?? ""
        let modelDir: URL
        if !selectedId.isEmpty,
           let selected = models.first(where: { $0.lastPathComponent == selectedId }) {
            modelDir = selected
        } else if let first = models.first {
            modelDir = first
        } else {
            print("[CHAT] ❌ No models found!")
            currentStats = "No model downloaded. Go to Models to download one."
            return
        }
        print("[CHAT] Loading model from: \(modelDir.path)")
        currentStats = "Loading model..."
        do {
            let manifest = try ModelManifest(modelDir: modelDir)
            print("[CHAT] Manifest parsed: \(manifest.hfConfig.numHiddenLayers) layers, \(manifest.hfConfig.vocabSize) vocab")
            try await engine.loadModel(from: manifest)
            print("[CHAT] ✅ Model loaded! State: \(engine.state)")
            if let info = engine.modelInfo {
                print("[CHAT] Model info: maxContext=\(info.maxContext), dirty=\(info.totalDirtyMB)MB")
            }
            currentStats = "Model loaded!"
        } catch {
            print("[CHAT] ❌ Load failed: \(error)")
            currentStats = "Load failed: \(error.localizedDescription)"
        }
    }

    private func sendMessageInternal(conversation: Conversation) {

        let text = inputText
        inputText = ""

        // 1. Create user message
        let userOrdinal = conversation.messages.count
        let userMessage = Message(role: .user, content: text, ordinal: userOrdinal)
        userMessage.conversation = conversation
        modelContext.insert(userMessage)

        // 2. Auto-generate title from first user message
        if conversation.title == "New Chat" {
            conversation.title = String(text.prefix(50))
        }

        // 3. Create assistant message placeholder
        let assistantOrdinal = conversation.messages.count
        let assistantMessage = Message(role: .assistant, content: "", ordinal: assistantOrdinal)
        assistantMessage.conversation = conversation
        modelContext.insert(assistantMessage)

        try? modelContext.save()

        // 4. Choose full generate vs continuation
        //    Turn 0 (first message): full prompt with system + history
        //    Turn 1+: continuation with just the new user text (reuses KV cache)
        isGenerating = true
        streamingText = ""
        currentStats = ""
        lastBatchTime = Date()

        // Decide: continuation (reuse KV cache) vs independent (reset + fresh prompt)
        let isFollowUp = engine.turnCount > 0 && looksLikeFollowUp(text)

        if needsReset || (engine.turnCount > 0 && !isFollowUp) {
            engine.resetConversation()
            needsReset = false
            print("[CHAT] KV cache reset (needsReset=\(needsReset), isFollowUp=\(isFollowUp))")
        }

        let stream: AsyncThrowingStream<GenerationEvent, Error>
        if isFollowUp {
            print("[CHAT] Using continuation (turn \(engine.turnCount)), follow-up detected")
            stream = engine.generateContinuation(text)
        } else {
            print("[CHAT] Using full generate (independent question), system prompt only")
            // Same system prompt + answer style guide as the cloud provider.
            let chatMessages = Self.onDeviceMessages(
                systemPrompt: conversation.systemPrompt,
                userText: text,
                styleEnabled: AssistantStylePreferences.isEnabled()
            )
            let prompt = PromptCompiler.compile(messages: chatMessages, addGenerationPrompt: true)
            stream = engine.generate(.formattedPrompt(prompt))
        }

        generationTask = Task { [weak self] in
            guard let self else { return }
            var accumulated = ""
            var inThinking = false
            var tokenCount = 0
            let genStartTime = Date()

            do {
                for try await event in stream {
                    guard !Task.isCancelled else { break }

                    switch event {
                    case .token(let text, _):
                        accumulated += text
                        self.streamingText = accumulated
                        tokenCount += 1

                        // Update live tok/s every token
                        let elapsed = Date().timeIntervalSince(genStartTime)
                        if elapsed > 0.1 {
                            let tps = Double(tokenCount) / elapsed
                            self.currentStats = String(format: "%d tokens • %.1f tok/s", tokenCount, tps)
                        }

                        // Batch-write to SwiftData every 500ms
                        let now = Date()
                        if now.timeIntervalSince(self.lastBatchTime) >= 0.5 {
                            assistantMessage.content = accumulated
                            self.lastBatchTime = now
                        }

                    case .thinkingStart:
                        inThinking = true

                    case .thinkingEnd:
                        inThinking = false

                    case .prefillProgress(let done, let total):
                        if total > 0 {
                            self.currentStats = "Prefill \(done)/\(total)"
                        }

                    case .throttled(let reason):
                        self.currentStats = "Throttled: \(reason)"

                    case .contextExhausted:
                        self.currentStats = "Context full"

                    case .finished(let stats):
                        assistantMessage.content = accumulated
                        let finalTps = stats.tokensPerSecond > 0
                            ? stats.tokensPerSecond
                            : (Date().timeIntervalSince(genStartTime) > 0
                               ? Double(tokenCount) / Date().timeIntervalSince(genStartTime)
                               : 0)
                        if finalTps > 0 {
                            self.currentStats = String(format: "%d tokens • %.1f tok/s • TTFT %.0fms",
                                                       stats.tokensGenerated > 0 ? stats.tokensGenerated : tokenCount,
                                                       finalTps,
                                                       stats.ttftMs)
                        }
                        conversation.updatedAt = Date()
                        try? self.modelContext.save()
                    }
                }
            } catch {
                if let ce = error as? CloudError, case .http(let code, _) = ce, code == 401 || code == 403 {
                    self.needsCloudKey = true
                }
                assistantMessage.content = accumulated.isEmpty
                    ? "Error: \(error.localizedDescription)"
                    : accumulated + "\n\n[Error: \(error.localizedDescription)]"
                try? self.modelContext.save()
            }

            // Final flush
            if assistantMessage.content != accumulated && !accumulated.isEmpty {
                assistantMessage.content = accumulated
                try? self.modelContext.save()
            }

            self.isGenerating = false
            self.streamingText = ""
            _ = inThinking  // suppress unused warning
        }
    }

    /// Sends the turn to NVIDIA's cloud API instead of the on-device engine.
    private func sendCloudMessage(conversation: Conversation) {
        let key = CloudSettings.apiKey ?? ""
        if key.isEmpty && CloudSettings.usesNVIDIA {
            currentStats = "Cloud is on but no API key is saved. Add one in Settings."
            return
        }
        let text = inputText
        inputText = ""

        // History before this turn, then the new user message. The system
        // prompt carries the same answer style guide as the on-device engine.
        let prior = sortedMessages.filter { !$0.content.isEmpty }
        let wire = Self.cloudMessages(
            systemPrompt: conversation.systemPrompt,
            history: prior.map { AssistantChatTurn(role: $0.role == .user ? "user" : "assistant", content: $0.content) },
            userText: text,
            styleEnabled: AssistantStylePreferences.isEnabled()
        )

        let userMessage = Message(role: .user, content: text, ordinal: conversation.messages.count)
        userMessage.conversation = conversation
        modelContext.insert(userMessage)
        if conversation.title == "New Chat" {
            conversation.title = String(text.prefix(50))
        }
        let assistantMessage = Message(role: .assistant, content: "", ordinal: conversation.messages.count)
        assistantMessage.conversation = conversation
        modelContext.insert(assistantMessage)
        try? modelContext.save()

        isGenerating = true
        streamingText = ""
        let model = CloudSettings.model
        currentStats = "Cloud: \(model)"
        lastBatchTime = Date()

        let temp = UserDefaults.standard.object(forKey: "temperature") as? Double ?? 0.7
        let maxTok = Int(UserDefaults.standard.object(forKey: "maxTokens") as? Double ?? 2048)
        let stream = NVIDIAClient.stream(messages: wire, model: model, apiKey: key, temperature: temp, maxTokens: maxTok)

        generationTask = Task { [weak self] in
            guard let self else { return }
            var accumulated = ""
            let start = Date()
            var chunks = 0
            do {
                for try await piece in stream {
                    guard !Task.isCancelled else { break }
                    accumulated += piece
                    chunks += 1
                    self.streamingText = accumulated
                    let now = Date()
                    if now.timeIntervalSince(self.lastBatchTime) >= 0.5 {
                        assistantMessage.content = accumulated
                        self.lastBatchTime = now
                    }
                }
            } catch {
                assistantMessage.content = accumulated.isEmpty
                    ? "Error: \(error.localizedDescription)"
                    : accumulated + "\n\n[Error: \(error.localizedDescription)]"
                try? self.modelContext.save()
            }
            if assistantMessage.content != accumulated && !accumulated.isEmpty {
                assistantMessage.content = accumulated
            }
            conversation.updatedAt = Date()
            try? self.modelContext.save()
            let secs = Date().timeIntervalSince(start)
            self.currentStats = String(format: "Cloud | %@ | %.1fs", model, secs)
            self.isGenerating = false
            self.streamingText = ""
        }
    }

    /// On-device (ChatML) messages for an independent question.
    nonisolated static func onDeviceMessages(systemPrompt: String, userText: String, styleEnabled: Bool) -> [ChatMessage] {
        AssistantPromptBuilder.messages(
            provider: .onDevice,
            baseSystemPrompt: systemPrompt,
            userText: userText,
            styleEnabled: styleEnabled
        ).map { ChatMessage(role: $0.role, content: $0.content) }
    }

    /// NVIDIA cloud messages. Qwen-only control lines (like /no_think) are dropped.
    nonisolated static func cloudMessages(
        systemPrompt: String,
        history: [AssistantChatTurn],
        userText: String,
        styleEnabled: Bool
    ) -> [CloudMessage] {
        AssistantPromptBuilder.messages(
            provider: .cloudNVIDIA,
            baseSystemPrompt: systemPrompt,
            history: history,
            userText: userText,
            styleEnabled: styleEnabled
        ).map { CloudMessage(role: $0.role, content: $0.content) }
    }

    /// Mark KV cache as stale — next send will do a full generate.
    func invalidateCache() {
        needsReset = true
    }

    /// Heuristic: does this message look like a follow-up to the previous conversation?
    /// Returns true if it contains referential language or is a short continuation-style query.
    private func looksLikeFollowUp(_ text: String) -> Bool {
        let lower = text.lowercased()

        // Referential patterns (Chinese + English)
        let followUpPatterns = [
            // Chinese referential
            "這個", "那個", "這些", "那些", "上面", "剛才", "之前",
            "繼續", "接著", "然後", "為什麼", "怎麼", "可以再",
            "補充", "詳細", "解釋一下", "舉個例", "比如",
            "還有", "另外", "除此之外",
            // Chinese pronouns referencing prior context
            "它", "他們", "她們", "它們",
            // English referential
            "this", "that", "these", "those", "above", "previous",
            "continue", "go on", "follow up", "elaborate", "explain more",
            "why did", "how does", "what about", "can you",
            "also", "additionally", "furthermore",
            // Short affirmations expecting continuation
            "yes", "ok", "好", "對", "是的", "沒錯",
        ]

        for pattern in followUpPatterns {
            if lower.contains(pattern) { return true }
        }

        // Very short messages (< 10 chars) after an existing conversation are likely follow-ups
        if text.count < 10 { return true }

        return false
    }

    func cancel() {
        print("[CHAT] stop tapped, isGenerating=\(isGenerating)")
        engine.cancel()
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
        streamingText = ""
    }
}
