# iOS Agent Automation Plan

PrivateAgent started as an offline iOS LLM runtime. The Android PrivateAgent experience is a closed loop: observe screen state, ask the model for the next action, execute it, then observe the new state. iOS does not expose an Android AccessibilityService equivalent to normal App Store apps, so this implementation is honest about capability boundaries and uses a bounded loop instead of pretending iOS can globally inspect or control other apps.

## Closed-loop runtime

The Agent Mode path is no longer a one-shot plan runner. `AgentLoop` drives:

`Goal -> Observe -> Plan -> Validate -> (Approval if needed) -> Execute -> Observe result -> Verify -> Recover/Retry -> Complete`

### State machine

| Phase | Meaning |
| --- | --- |
| `idle` | No run |
| `understanding` | Normalize the user goal |
| `observing` | Collect the current in-app or Mac-bridge observation |
| `planning` | Rule-based or local-model planner |
| `validating` | Schema, capability, and policy checks |
| `awaitingApproval` | High-risk / external-control pause |
| `executing` | One action via the executor router |
| `verifying` | Separate executor success from observation proof |
| `recovering` | Classify the failure and retry, re-observe, fall back, or stop |
| `completed` / `failed` / `cancelled` / `blocked` | Terminal |

Hard limits, with no unbounded loops:

| Limit | Value |
| --- | --- |
| Max agent steps | 32 |
| Max JSON repair attempts | 3 |
| Max action retries | 2 |
| Max recovery attempts | 2 |

## Architecture

| Layer | Responsibility | Implementation |
| --- | --- | --- |
| AgentCore | Shared observation, action, plan, risk, capability, loop, and policy models | `Sources/AgentCore` |
| State machine | Explicit legal phase transitions | `AgentStateMachine`, `AgentPhase` |
| Loop | Bounded observe/plan/act/verify cycle | `AgentLoop` |
| Planner | Converts a user goal and observation into a safe plan | `RuleBasedAgentPlanner`, `LLMAgentPlanner` |
| JSON repair | Extract JSON, decode, re-prompt on the specific schema violation | `JSONRepairEngine` |
| Validator | Schema/semantic checks, capability availability, risk policy | `PlanValidator` |
| Policy | Permission / risk / approval decisions | `AgentPolicy`, `AgentApprovalBroker` |
| Prompt compiler | Creates the model prompt for strict JSON planning | `AgentPromptCompiler` |
| Local model adapter | Uses the loaded on-device model to produce planning JSON | `PrivateAgentEngineTextGenerator` |
| Session | Holds allowed modes and latest rule-based plan | `AgentSession` actor |
| UI bridge | Presents live Agent Mode state in SwiftUI | `AgentModeView`, `AgentModeViewModel` |
| Executors | Runs approved actions with capability fallback | `PlanRunner`, `ActionExecutorRouter`, URL and Shortcuts executors |
| Verification | `ACTION_SUCCESS` vs `ACTION_VERIFIED` | `ActionVerifier`, `GoalVerifier` |
| Recovery | Transient retry, wrong-target re-observe, permission guidance, capability fallback, or stop | `RecoveryEngine`, `CapabilityFallback` |
| Mac bridge | Cross-app observation/action handoff | `MacBridgeClient`, `LocalBridgeClient`, `MacBridgeActionExecutor` |

Plan steps now carry `id`, `action`, `target`, `risk`, `requiresApproval`, `expectedResult`, and a `verification` spec (`none`, `url_contains`, `visible_text_contains`, `control_exists`, `app_context_contains`, `state_predicate`).

Executor success is not the same as proof:

- **ACTION_SUCCESS**: the executor returned ok.
- **ACTION_VERIFIED**: a later observation matches the step's expected result or verification spec.

Capability fallback order when a primary executor is unavailable:

`in-app -> App Intents -> URL scheme -> Shortcuts -> Mac bridge`

## Automation modes

| Mode | App Store safe | Reads other apps | Controls other apps | Use case |
| --- | --- | --- | --- | --- |
| In-app | Yes | No | No | PrivateAgent chat, model manager, local workflows |
| App Intents | Yes | No | No | Explicit app/system capabilities exposed through intents |
| Shortcuts | Yes | No | No | User-approved routines and handoffs |
| Mac-assisted | Yes | Yes | Yes | Closest practical Android-like experience with a trusted paired Mac |
| WebDriverAgent/XCTest | No for consumer runtime | Yes | Yes | Developer/test-device automation |
| Jailbreak/private entitlement | No | Yes | Yes | Most Android-like, but fragile and non-App-Store-safe |

## Implemented

- Agent Mode screen from the app shell, with live phase, step, verification, approval, and cancel UI.
- Bounded closed-loop `AgentLoop` with an explicit state machine.
- Rule-based planning plus local-model JSON planning.
- `JSONRepairEngine` with a 3-attempt schema-violation repair budget.
- `PlanValidator`, `AgentPolicy`, and approval broker.
- Plan runner, action executor router, URL/Shortcuts executors, and capability fallback.
- `ActionVerifier` / `GoalVerifier` distinguishing executor success from observation proof.
- `RecoveryEngine` classification: transient, wrong target, permission, unavailable capability, impossible.
- Mac bridge protocol and local HTTP client contracts.
- AgentCore is Foundation-only. UIKit stays behind `#if canImport(UIKit)` in `PrivateAgentUI`.
- Linux host builds: `Package.swift` exposes only `AgentCore` on Linux so `swift build` and `swift test` run without Metal/UIKit.
- Unit tests for the state machine, loop limits, JSON repair, validator, verifier, and recovery classification.

## Not possible on normal iOS

These Android PrivateAgent behaviors are **not** available to an App Store iOS app, and this code does not pretend otherwise:

- Global screen observation of other apps (no AccessibilityService / UIAutomation for third-party apps).
- Arbitrary tap / type / scroll / swipe inside other apps from the PrivateAgent process.
- Reading another app's view hierarchy, notifications, or clipboard as a default observation source.
- A true visual closed loop over the whole phone without a paired Mac, WebDriverAgent/XCTest on a developer device, or a jailbreak/private-entitlement bridge.
- Silent privileged UI control through the default Mac helper. The checked-in helper is guarded and does not inject keystrokes or scrape the iPhone UI.

When a goal needs those capabilities, the planner must hand off to an allowed external mode or ask the user.

## Remaining work that needs Xcode / a device

1. Full `swift build` / `swift test` of FlashMoE, Metal, and `PrivateAgentUI` on macOS (Linux only builds AgentCore).
2. Xcode iOS app compile, signing, and on-device Agent Mode run.
3. App Intents executor for first-party integrations.
4. A paired Mac helper that implements privileged observation/action adapters from `Docs/MAC_BRIDGE_PROTOCOL.md`.
5. WebDriverAgent bridge for developer/test-device automation.
6. Richer in-app observation (visible SwiftUI controls) beyond the current goal/context snapshot.

## Safety rules

- Require explicit approval for external control, account changes, purchases, destructive edits, privacy-sensitive reads, or high-risk bridge modes.
- Never tell the planner that normal iOS can globally inspect third-party apps.
- Treat Mac-assisted, WebDriverAgent, and jailbreak modes as opt-in capabilities.
- Keep local/offline planning as the default path when possible.
- Fail closed when JSON repair, validation, or recovery budgets are exhausted.
