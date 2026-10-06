# WebDriverAgent Protocol

WebDriverAgent/XCTest is a **developer-device** path. It is not App Store safe and is not part of the consumer Agent Mode runtime. PrivateAgent talks to a local adapter, not directly to XCTest, so the iOS planning layer stays the same as Mac-assisted mode.

## Check WDA (sessions, no token)

WebDriverAgent needs a WebDriver **session**, not a token. **Check WDA** in Agent Mode (`WebDriverAgentSessionManager` / `WebDriverAgentProbe` in AgentCore):

1. `GET /status` on the configured host:port. If the host is `127.0.0.1` and the port isn't answering, it also tries `127.0.0.1:8100`, where WebDriverAgentRunner listens on the iPhone itself, and switches the port when that works.
2. It identifies what answered:
   - **WebDriverAgent directly** (`{"value": {"ready": true, ...}}`): it reuses the stored session id if `GET /session/<id>` still works, otherwise adopts the session advertised by `/status`, otherwise sends `POST /session` with `{"capabilities": {"alwaysMatch": {}, "firstMatch": [{}]}}`. The session id is stored per host:port. A session id isn't a secret, so it lives in UserDefaults.
   - **The Str8ZeRO adapter** (`{"ready": ..., "sessionId": ...}`): the adapter manages the session, and the app records the id it reports.
3. The live status is one of: Ready (session new/reused), Not ready, Session failed (with WDA's reason), Adapter needs a token, or Unreachable (with a hint).

During a run, `ManagedWebDriverAgentClient` talks to WDA directly: `/session/<id>/source`, element find, click, value, and url. If WDA answers `invalid session id`, it creates a new session and retries once. **New WDA Session** in the UI forces a fresh session.

## Adapter process

`Bridge/wda_adapter.py` implements the adapter protocol on a computer that can reach WebDriverAgent:

```bash
python3 Bridge/wda_adapter.py --host 0.0.0.0 --port 8101 --wda-url http://127.0.0.1:8100
```

Point Agent Mode at `http://<computer LAN IP>:8101`. `127.0.0.1` in the app always means the iPhone itself. The adapter validates and reuses its WDA session, recreates it when WDA reports it expired, maps `/observation` onto `/session/<id>/source`, and maps tap/type onto element find plus click/value. No token is needed. `--token` exists only for older app builds.

## When to use it

- A personal or CI device with WebDriverAgent or an XCTest runner installed.
- Debugging closed-loop tap/type/scroll against a real springboard or app.
- Never as a silent background service on a customer's phone.

## Adapter shape

Default development URL:

```text
http://127.0.0.1:8100
```

Optional bearer token (legacy; current app builds don't send one unless a token was migrated from an older build):

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
