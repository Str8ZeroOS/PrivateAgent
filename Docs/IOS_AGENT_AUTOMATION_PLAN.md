# iOS Agent Automation Plan

PrivateAgent started as an offline iOS LLM runtime. The Android-style PrivateAgent experience is different: it observes phone state, plans actions, and executes taps, typing, scrolling, and app handoffs in a loop. iOS does not expose an Android Accessibility Services equivalent to normal App Store apps, so the implementation needs explicit modes with honest capability boundaries.

## Architecture

| Layer | Responsibility | Initial implementation |
| --- | --- | --- |
| AgentCore | Shared observation, action, plan, risk, and capability models | `Sources/AgentCore` |
| Planner | Converts a user goal and observation into a safe plan | `RuleBasedAgentPlanner`, later replaceable with local/API LLM planner |
| Prompt compiler | Creates the model prompt for JSON planning | `AgentPromptCompiler` |
| Session | Holds allowed modes and latest plan | `AgentSession` actor |
| UI bridge | Presents Agent Mode in SwiftUI | `AgentModeViewModel` |
| Executors | Runs approved actions | Next phase |

## Automation modes

| Mode | App Store safe | Reads other apps | Controls other apps | Use case |
| --- | --- | --- | --- | --- |
| In-app | Yes | No | No | PrivateAgent chat, model manager, local workflows |
| App Intents | Yes | No | No | Explicit app/system capabilities exposed through intents |
| Shortcuts | Yes | No | No | User-approved routines and handoffs |
| Mac-assisted | Yes | Yes | Yes | Closest practical Android-like experience with a trusted paired Mac |
| WebDriverAgent/XCTest | No for consumer runtime | Yes | Yes | Developer/test-device automation |
| Jailbreak/private entitlement | No | Yes | Yes | Most Android-like, but fragile and non-App-Store-safe |

## Next implementation phases

1. Add an Agent Mode screen to the iOS app.
2. Add a JSON LLM planner that uses `AgentPromptCompiler` and the existing local engine when a model is loaded.
3. Add action executors for in-app commands, URLs, Shortcuts, and App Intents.
4. Add user approval UI for medium/high-risk actions.
5. Add a Mac bridge protocol for screen observations and action execution.
6. Add optional WebDriverAgent bridge for developer devices.
7. Add telemetry-free local run logs so users can inspect what the agent did.

## First executors to build

- `InAppActionExecutor`: answers, asks the user, and navigates PrivateAgent-owned screens.
- `URLActionExecutor`: opens safe URLs after approval.
- `ShortcutActionExecutor`: invokes named shortcuts through supported system APIs or URL schemes.
- `MacBridgeActionExecutor`: sends handoff payloads to a paired local bridge.

## Safety rules

- Require explicit approval for external control, account changes, purchases, destructive edits, privacy-sensitive reads, or high-risk bridge modes.
- Never tell the planner that normal iOS can globally inspect third-party apps.
- Treat Mac-assisted, WebDriverAgent, and jailbreak modes as opt-in capabilities.
- Keep local/offline planning as the default path when possible.
