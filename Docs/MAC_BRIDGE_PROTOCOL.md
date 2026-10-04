# Mac Bridge Protocol

The Mac bridge is the App-Store-safe path for Android-like iPhone automation. PrivateAgent on iOS stays honest about platform limits and delegates cross-app observation/control to a trusted local Mac process.

## Base URL

The default development shape is a loopback HTTP service, for example:

```text
http://127.0.0.1:8765
```

Production pairing should add device authentication and local-network trust before enabling actions.

## Endpoints

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
  "message": "Captured current mirrored iPhone state.",
  "observation": {
    "source": "macBridge",
    "userGoal": "Open YouTube and tap the latest Tech Jarves video",
    "visibleText": ["YouTube", "Tech Jarves"],
    "controls": [
      { "id": "latest-video", "label": "I Put AI Agents on My Android Phone", "role": "button", "isEnabled": true }
    ],
    "appContext": "iPhone Mirroring",
    "timestamp": "2026-10-04T12:00:01Z"
  }
}
```

### `POST /action`

Request:

```json
{
  "sessionId": "00000000-0000-0000-0000-000000000001",
  "action": { "tap": { "controlId": "latest-video" } },
  "requiresUserApproval": true
}
```

Response:

```json
{
  "status": "completed",
  "message": "Tapped latest-video."
}
```

## Required bridge behavior

- Refuse actions unless the iOS app has paired with the Mac helper.
- Keep user-visible logs of observations and actions.
- Treat tap/type/scroll actions as privileged.
- Require approval for account, purchase, destructive, or privacy-sensitive workflows.
- Return stable control IDs for the current observation frame.
- Return `failed` when the screen has changed enough that a control ID no longer resolves.

## Suggested Mac-side adapters

- iPhone Mirroring plus accessibility inspection where available.
- XCTest/WebDriverAgent for developer devices.
- Screen capture plus OCR/vision as a fallback.
- Native macOS automation only for the helper UI, not for hidden actions.
