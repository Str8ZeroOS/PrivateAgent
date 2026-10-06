# Mac Bridge Protocol

The Mac bridge is the App-Store-safe path for Android-like iPhone automation. PrivateAgent on iOS stays honest about platform limits and delegates blocked or cross-device work to a trusted local Mac process.

## Base URL

The default development shape is a local-network HTTP service, for example:

```text
http://192.168.12.110:8765
```

Every endpoint except `POST /pair` requires a bearer token:

```text
Authorization: Bearer <device-token>
```

The iPhone gets that token through a one-time pairing code instead of the user pasting it.

## Pairing

1. `Bridge/mac_bridge_helper.py` prints a 6-digit pairing code when it starts. The code is single use, expires after 5 minutes (`--pairing-ttl`), and is replaced automatically.
2. In Str8ZeRO > Agent Mode > Mac Bridge the user taps **Check Bridge**. `GET /health` without a token returns `401` with `"pairing": "available"`, so the app shows *Reachable, not paired* and asks for the code.
3. The app sends `POST /pair` with the code. The bridge returns a random 256-bit token. The app stores it in the iOS Keychain (`AfterFirstUnlockThisDeviceOnly`, keyed by bridge host:port). The bridge stores only a SHA-256 hash of it in `~/.privateagent/bridge_devices.json`.
4. After that, every request carries the token. If the bridge rejects it (for example after `--forget-devices`), the app shows *Token invalid*, deletes the token, and asks for a new code.

Rate limits: a code is dropped after 5 wrong attempts. After 15 wrong attempts in total, pairing locks until the bridge restarts. Tokens and codes are compared in constant time. Tokens are never printed or logged; only `****abcd`-style redactions are.

`--token <value>` still turns on a legacy static token for older scripts. `--no-pairing` turns off `/pair`.

### `POST /pair` (no auth)

Request:

```json
{ "code": "482913", "deviceName": "Str8ZeRO on iPhone" }
```

Responses:

| Status | Body | Meaning |
|---|---|---|
| 200 | `{"token": "<64 hex>", "service": "PrivateAgent Mac Bridge", "deviceName": "..."}` | Paired |
| 400 | `{"error": "invalid_request"}` | Code missing or not 6 digits |
| 403 | `{"error": "invalid_code", "attemptsRemaining": 3}` | Wrong code |
| 403 | `{"error": "pairing_disabled"}` | Started with `--no-pairing` |
| 410 | `{"error": "code_expired"}` | Code expired; a new one is printed |
| 429 | `{"error": "pairing_locked"}` | Too many wrong codes; restart the bridge |

### Unauthorized responses

```json
{ "error": "unauthorized", "reason": "missing_token" | "invalid_token", "pairing": "available" | "locked" | "disabled" }
```

## Endpoints

### `GET /health`

Response:

```json
{
  "status": "ok",
  "service": "PrivateAgent Mac Bridge",
  "mode": "guarded-actions",
  "host": "Jay.lan",
  "frontmostApp": "Safari",
  "capabilities": ["health", "frontmostAppObservation", "openURL", "openAllowlistedMacApp", "wait", "actionAuditLog"]
}
```

### `POST /observation`

Request:

```json
{
  "sessionId": "00000000-0000-0000-0000-000000000001",
  "goal": "Open YouTube and tap the latest Tech Jarves video",
  "requestedAt": "2026-10-04T12:00:00Z"
}
```

Response:

```json
{
  "status": "completed",
  "message": "Captured Mac bridge context.",
  "observation": {
    "source": "macBridge",
    "userGoal": "Open YouTube and tap the latest Tech Jarves video",
    "visibleText": ["Mac bridge connected", "Frontmost app: Safari"],
    "controls": [],
    "appContext": "Mac bridge helper on Jay.lan",
    "timestamp": "2026-10-04T12:00:01Z"
  }
}
```

### `POST /action`

Request:

```json
{
  "sessionId": "00000000-0000-0000-0000-000000000001",
  "action": { "openURL": { "_0": "https://youtube.com/@TechJarves" } },
  "requiresUserApproval": true
}
```

Response:

```json
{
  "status": "completed",
  "message": "Opened URL on Mac: https://youtube.com/@TechJarves"
}
```

## Current Guarded Helper

`Bridge/mac_bridge_helper.py` is intentionally conservative and supports older Macs that only have Python 2.7 available. It can:

- report bridge health and available capabilities;
- report the frontmost Mac app as an observation signal;
- open `http://` and `https://` URLs;
- open a small allowlist of built-in Mac apps;
- wait for a bounded duration;
- log handoff, tap, type, and scroll requests without silently performing privileged UI control.

Privileged adapters stay off unless the helper is launched with explicit flags:

- `--enable-accessibility-actions`: type, arrow-key scroll, key codes, and AX click by control id/label
- `--enable-ax-observation`: include frontmost-app System Events UI element names as observation controls
- `--enable-clipboard-observation`: include a short clipboard summary
- `--enable-iphone-mirroring`: if the frontmost Mac app is iPhone Mirroring, set `observation.source` to `iphoneMirroring` and label the app context as the mirrored window. Pair with `--enable-ax-observation` to include that window's AX names.

Without those flags the helper still does not read the clipboard, inject keystrokes, scrape screen contents, or click UI elements. It never controls the iPhone UI directly. iPhone Mirroring observation is Mac-side AX of the mirrored window, not an iOS AccessibilityService.

## Required Bridge Behavior

- Refuse requests unless the iOS app has paired with the Mac helper.
- Keep user-visible logs of observations and actions.
- Treat tap/type/scroll actions as privileged.
- Require approval for account, purchase, destructive, or privacy-sensitive workflows.
- Return stable control IDs for a real observation adapter's current frame.
- Return `failed` when the screen has changed enough that a control ID no longer resolves.

## Next Adapters

To get closer to Android-style automation, add adapters in this order:

1. **iPhone Mirroring adapter (opt-in)**: `--enable-iphone-mirroring` classifies the frontmost iPhone Mirroring window. Combine with `--enable-ax-observation` for AX names from that window. This is still Mac-side observation, not a true iOS accessibility dump.
2. **XCTest/WebDriverAgent adapter**: operate on developer devices where test automation is allowed.
3. **Accessibility adapter**: perform tap/type/scroll only after explicit user approval and macOS permission setup.
4. **OCR/vision fallback**: identify visible text when structured accessibility metadata is unavailable.

Each adapter should plug into the same `/observation` and `/action` protocol instead of changing the iOS planning layer.

Agent Mode now composes these adapters at runtime: when Mac-assisted or WebDriverAgent is allowed and a host is configured, `CapabilityRuntime` observes and executes through that client instead of leaving the contracts unused.

To pair an iPhone, start the bridge (`Scripts/start-mac-bridge.sh` on a Mac, `Scripts/start-bridge-windows.ps1` on Windows, or `python Bridge/mac_bridge_helper.py`) and enter the printed pairing code under **Check Bridge**. The printed `privateagent://pair?host=…&port=…&code=…` link does the same thing. See `Docs/MAC_IPHONE_PAIRING.md`.
