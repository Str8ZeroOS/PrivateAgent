# WebDriverAgent Protocol

WebDriverAgent/XCTest is a **developer-device** path. It is not App Store safe and is not part of the consumer Agent Mode runtime. PrivateAgent talks to a local adapter, not directly to XCTest, so the iOS planning layer stays the same as Mac-assisted mode.

## When to use it

- A personal or CI device with WebDriverAgent or an XCTest runner installed.
- Debugging closed-loop tap/type/scroll against a real springboard or app.
- Never as a silent background service on a customer's phone.

## Adapter shape

Default development URL:

```text
http://127.0.0.1:8100
```

Optional bearer token:

```text
Authorization: Bearer <developer-token>
```

The adapter may wrap raw WDA (`/status`, `/session`, element find/click) behind these stable endpoints so AgentCore does not encode WDA session details.

### `GET /status`

```json
{
  "ready": true,
  "message": "WebDriverAgent adapter ready",
  "sessionId": "wda-session"
}
```

### `POST /observation`

Request:

```json
{
  "sessionId": "00000000-0000-0000-0000-000000000001",
  "goal": "Open Settings and tap Wi-Fi",
  "requestedAt": "2026-10-04T12:00:00Z"
}
```

Response:

```json
{
  "status": "completed",
  "message": "Captured developer-device UI.",
  "wdaSessionId": "wda-session",
  "observation": {
    "source": "webDriverAgent",
    "userGoal": "Open Settings and tap Wi-Fi",
    "visibleText": ["Settings", "Wi-Fi"],
    "controls": [
      { "id": "wifi", "label": "Wi-Fi", "role": "button", "isEnabled": true }
    ],
    "appContext": "Settings",
    "timestamp": "2026-10-04T12:00:01Z"
  }
}
```

### `POST /action`

Request:

```json
{
  "sessionId": "00000000-0000-0000-0000-000000000001",
  "action": { "tap": { "controlId": "wifi" } },
  "requiresUserApproval": true
}
```

Response:

```json
{
  "status": "completed",
  "message": "Tapped Wi-Fi"
}
```

## Safety

- Require an explicit allowed mode of `webDriverAgent`.
- Treat every tap/type/scroll as approval-gated.
- Return `failed` when a control ID is stale.
- Do not enable this adapter in App Store builds.
