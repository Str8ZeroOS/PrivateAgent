# Answer style

Str8ZeRO answers follow one style in chat (on-device model and NVIDIA cloud) and in Agent Mode.

- The guide lives in one place: `AssistantStyleGuide.prompt` in `Sources/AgentCore/AssistantStyle.swift`.
- `AssistantPromptBuilder` appends the guide to the conversation's system prompt for both providers (`.onDevice` ChatML and `.cloudNVIDIA` chat messages). The cloud path also drops Qwen-only lines like `/no_think`. The guide is never appended twice.
- The Agent Mode JSON planner gets a short version (`agentActionTextPrompt`) that covers only the user-facing `answer`/`askUser` text. Plans are still JSON only.
- `AgentRunSummaryFormatter` turns any run snapshot (from the rule-based or the local-model planner) into the outcome first, then each sub-goal with verified / blocked / failed / not started and the reason, then numbered next steps. It says "Done" only when every sub-goal was verified. "Run Plan Once" is reported as "ran, not verified".
- Chat bubbles render Markdown blocks (`MarkdownBlockParser` plus `MarkdownText`): paragraphs, headings, numbered and bullet lists, fenced code blocks, quotes, and inline bold, code, and links. User messages are shown as typed.
- **Settings > Answer Style > Consistent answer style** (on by default, key `PrivateAgent.answerStyleEnabled`) turns the style prompt and the formatted run summaries on or off. Markdown rendering stays on either way.
