# Mac Bridge Protocol

The Mac bridge is the App-Store-safe path for Android-like iPhone automation. PrivateAgent on iOS stays honest about platform limits and delegates blocked or cross-device work to a trusted local Mac process.

## Base URL

The default development shape is a local-network HTTP service, for example:

```text
http://192.168.12.110:8765
```

The development helper requires a bearer token on every request:

```text
Authorization: Bearer <pairing-token>
```

Production pairing should add stronger device identity, token rotation, local-network trust, and a user-visible approval ledger before enabling privileged actions.

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
