# iOS Agent Automation Plan

PrivateAgent started as an offline iOS LLM runtime. The Android-style PrivateAgent experience is different: it observes phone state, plans actions, and executes taps, typing, scrolling, and app handoffs in a loop. iOS does not expose an Android Accessibility Services equivalent to normal App Store apps, so the implementation uses explicit modes with honest capability boundaries.

## Architecture

| Layer | Responsibility | Implementation |
| --- | --- | --- |
| AgentCore | Shared observation, action, plan, risk, and capability models | `Sources/AgentCore` |
| Planner | Converts a user goal and observation into a safe plan | `RuleBasedAgentPlanner`, `LLMAgentPlanner` |
| Prompt compiler | Creates the model prompt for strict JSON planning | `AgentPromptCompiler` |
| Local model adapter | Uses the loaded on-device model to produce planning JSON | `PrivateAgentEngineTextGenerator` |
| Session | Holds allowed modes and latest rule-based plan | `AgentSession` actor |
| UI bridge | Presents Agent Mode in SwiftUI | `AgentModeView`, `AgentModeViewModel` |
| Executors | Runs approved actions | `PlanRunner`, `ActionExecutorRouter`, URL and Shortcuts executors |
| Mac bridge | Defines cross-app observation/action handoff | `MacBridgeClient`, `LocalBridgeClient`, `MacBridgeActionExecutor` |

## Automation modes

| Mode | App Store safe | Reads other apps | Controls other apps | Use case |
| --- | --- | --- | --- | --- |
| In-app | Yes | No | No | PrivateAgent chat, model manager, local workflows |
| App Intents | Yes | No | No | Explicit app/system capabilities exposed through intents |
| Shortcuts | Yes | No | No | User-approved routines and handoffs |
| Mac-assisted | Yes | Yes | Yes | Closest practical Android-like experience with a trusted paired Mac |
| WebDriverAgent/XCTest | No for consumer runtime | Yes | Yes | Developer/test-device automation |
| Jailbreak/private entitlement | No | Yes | Yes | Most Android-like, but fragile and non-App-Store-safe |

## Implemented phases

1. Agent Mode screen exposed from the app shell.
2. Rule-based planning for starter behavior and guardrails.
3. Strict JSON prompt compiler for LLM planning.
4. Local model planner adapter using `PrivateAgentEngine.generate`.
5. Plan runner and action executor router.
6. URL and Shortcuts action executors.
7. Mac bridge protocol and local HTTP client contracts.
8. Unit tests for planner, JSON decoding, and plan runner behavior.

## Remaining phases

1. Run a full Xcode/SPM compile pass and fix any compiler errors.
2. Add richer approval UI before medium/high-risk execution.
3. Add App Intents executor for first-party integrations.
4. Build the paired Mac helper that implements `Docs/MAC_BRIDGE_PROTOCOL.md`.
5. Add local run history so users can inspect every observation, plan, action, and result.
6. Add retry/repair flow when local model JSON fails to decode.
7. Add WebDriverAgent bridge for developer/test-device automation.

## Safety rules

- Require explicit approval for external control, account changes, purchases, destructive edits, privacy-sensitive reads, or high-risk bridge modes.
- Never tell the planner that normal iOS can globally inspect third-party apps.
- Treat Mac-assisted, WebDriverAgent, and jailbreak modes as opt-in capabilities.
- Keep local/offline planning as the default path when possible.
