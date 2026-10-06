import Foundation

/// Where an answer is generated. Both providers get the same style guide.
public enum AssistantProvider: String, Sendable, Codable, Equatable, CaseIterable {
    /// The on-device Qwen/Flash-MoE engine (ChatML prompt).
    case onDevice
    /// NVIDIA cloud (Nemotron, OpenAI-compatible chat messages).
    case cloudNVIDIA
}

/// The single assistant style guide shared by chat (on-device and cloud) and
/// Agent Mode. Edit it here only.
public enum AssistantStyleGuide {
    /// Marker line so the guide is never appended twice.
    public static let marker = "## Str8ZeRO answer style"

    public static let prompt = """
    \(marker)
    Follow this style in every reply:
    - Lead with the answer or result in the first sentence, then give detail.
    - Write plain, warm, concise, complete sentences. No filler openers ("Great question", "Sure!", "Certainly") and no filler closings ("Hope this helps", "Let me know if...").
    - When the user must do something, give numbered steps with the exact taps, menu names, and values (for example: 1. Open **Settings**. 2. Tap **Wi-Fi**. 3. Turn on **Ask to Join Networks**.).
    - Use bullets only for parallel items. Use bold only for the single most critical fact.
    - Put code, file paths, commands, and settings values in `code spans`, and multi-line code in fenced code blocks with a language tag.
    - Write links as Markdown links with short labels, like [Apple Support](https://support.apple.com).
    - Be honest about status: say something is done only when it was verified. Otherwise say it is blocked or failed, why, and the next step.
    - Match length to the question: a one-line answer for a simple question, more only when needed.
    """

    /// Short version for the Agent Mode JSON planner, where only the text
    /// inside `answer` / `askUser` actions is user-facing.
    public static let agentActionTextPrompt = """
    Text style for "answer" and "askUser" strings: lead with the result, use plain, warm, concise complete sentences, no filler openers or closings, and never claim something is done unless it was verified. When the user asked you to reply or say an exact phrase, return exactly that phrase.
    """
}

public enum AssistantStylePreferences {
    /// UserDefaults key for the Settings toggle "Consistent answer style".
    public static let enabledKey = "PrivateAgent.answerStyleEnabled"

    /// Defaults to on when the user never touched the toggle.
    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }
}

/// One role/content message, independent of the on-device (`ChatMessage`)
/// and cloud (`CloudMessage`) wire types.
public struct AssistantChatTurn: Sendable, Equatable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// Builds the system prompt and message list for either provider, applying
/// the shared style guide when enabled.
public enum AssistantPromptBuilder {
    /// Qwen-only control lines (like `/no_think`) that cloud models don't understand.
    public static let onDeviceControlLines: Set<String> = ["/no_think", "/think"]

    public static func systemPrompt(base: String, provider: AssistantProvider, styleEnabled: Bool) -> String {
        var lines = base.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if provider == .cloudNVIDIA {
            lines.removeAll { onDeviceControlLines.contains($0.trimmingCharacters(in: .whitespaces)) }
        }
        var prompt = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard styleEnabled, !prompt.contains(AssistantStyleGuide.marker) else { return prompt }
        if prompt.isEmpty {
            prompt = AssistantStyleGuide.prompt
        } else {
            prompt += "\n\n" + AssistantStyleGuide.prompt
        }
        return prompt
    }

    /// Messages for one chat turn. `history` is earlier turns (oldest first).
    /// The on-device engine starts each independent question fresh, so callers
    /// usually pass an empty history for `.onDevice`.
    public static func messages(
        provider: AssistantProvider,
        baseSystemPrompt: String,
        history: [AssistantChatTurn] = [],
        userText: String,
        styleEnabled: Bool
    ) -> [AssistantChatTurn] {
        var turns: [AssistantChatTurn] = []
        let system = systemPrompt(base: baseSystemPrompt, provider: provider, styleEnabled: styleEnabled)
        if !system.isEmpty {
            turns.append(AssistantChatTurn(role: "system", content: system))
        }
        turns.append(contentsOf: history.filter { !$0.content.isEmpty && $0.role != "system" })
        turns.append(AssistantChatTurn(role: "user", content: userText))
        return turns
    }
}
