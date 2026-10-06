#!/usr/bin/env python3
"""Developer-device WebDriverAgent adapter for PrivateAgent.

Translates Docs/WEBDRIVERAGENT_PROTOCOL.md into raw WDA/XCTest HTTP calls.
Not App Store safe. Run only on a machine that already hosts WebDriverAgent.

    python3 Bridge/wda_adapter.py --host 0.0.0.0 --wda-url http://127.0.0.1:8100

No token is needed: Str8ZeRO's "Check WDA" probes /status and the adapter
creates or reuses the WebDriverAgent session itself (recreating it if WDA
reports the session expired). --token is optional and only for older app
builds that still sent a static WDA token.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn


def iso_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def wda_request(base_url: str, method: str, path: str, body=None, timeout: float = 8.0):
    url = base_url.rstrip("/") + path
    data = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read().decode("utf-8")
            return response.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        try:
            payload = json.loads(raw) if raw else {"error": str(exc)}
        except json.JSONDecodeError:
            payload = {"error": raw or str(exc)}
        return exc.code, payload
    except Exception as exc:  # noqa: BLE001
        return 0, {"error": str(exc)}


def parse_action(action):
    if not isinstance(action, dict) or not action:
        return None, {}
    name = next(iter(action.keys()))
    payload = action.get(name) or {}
    if not isinstance(payload, dict):
        payload = {"value": payload}
    return name, payload


def observation_from_source(goal: str, source_xml: str, session_id: str | None):
    labels = []
    controls = []
    remaining = source_xml
    while 'name="' in remaining and len(controls) < 40:
        start = remaining.find('name="') + 6
        end = remaining.find('"', start)
        if end < 0:
            break
        label = remaining[start:end].strip()
        remaining = remaining[end + 1 :]
        if not label or label in labels:
            continue
        labels.append(label)
        controls.append(
            {
                "id": "wda-%d" % len(controls),
                "label": label,
                "role": "unknown",
                "isEnabled": True,
            }
        )
    return {
        "source": "webDriverAgent",
        "userGoal": goal,
        "visibleText": labels[:20] or ["WebDriverAgent connected"],
        "controls": controls,
        "appContext": "WebDriverAgent",
        "timestamp": iso_now(),
    }


def is_invalid_session(status: int, payload) -> bool:
    value = payload.get("value") if isinstance(payload, dict) else None
    error = ""
    if isinstance(value, dict):
        error = value.get("error") or ""
    if not error and isinstance(payload, dict):
        error = payload.get("error") or ""
    return error == "invalid session id" or (status == 404 and not error)


class AdapterState:
    def __init__(self, token: str, wda_url: str):
        self.token = token
        self.wda_url = wda_url.rstrip("/")
        self.session_id = None

    def session_alive(self, session_id: str) -> bool:
        status, payload = wda_request(self.wda_url, "GET", "/session/%s" % session_id)
        if status != 200:
            return False
        value = payload.get("value") if isinstance(payload, dict) else None
        return not (isinstance(value, dict) and value.get("error"))

    def ensure_session(self, force_new: bool = False):
        """Reuse a live WDA session, or create one. Recreates expired sessions."""
        status, payload = wda_request(self.wda_url, "GET", "/status")
        if status == 0:
            return False, "WebDriverAgent is not reachable at %s: %s" % (self.wda_url, payload.get("error"))
        if status != 200:
            return False, "WebDriverAgent /status returned HTTP %s" % status
        value = payload.get("value") or {}
        if isinstance(value, dict) and value.get("ready") is False:
            return False, value.get("message") or "WebDriverAgent is not ready."
        if force_new:
            self.session_id = None
        if self.session_id and self.session_alive(self.session_id):
            return True, "session reused"
        self.session_id = None
        advertised = payload.get("sessionId") or (value.get("sessionId") if isinstance(value, dict) else None)
        if advertised and self.session_alive(advertised):
            self.session_id = advertised
            return True, "session adopted"
        status, payload = wda_request(
            self.wda_url,
            "POST",
            "/session",
            {"capabilities": {"alwaysMatch": {}, "firstMatch": [{}]}},
            timeout=30.0,
        )
        if status in (200, 201):
            value = payload.get("value") or payload
            self.session_id = value.get("sessionId") or payload.get("sessionId")
            if self.session_id:
                return True, "session created"
        value = payload.get("value") if isinstance(payload, dict) else None
        reason = (value or {}).get("message") if isinstance(value, dict) else None
        return False, reason or payload.get("error") or "WebDriverAgent refused to create a session."

    def session_request(self, method: str, path: str, body=None):
        """Call /session/<id><path>; recreate the session once if it expired."""
        ok, message = self.ensure_session()
        if not ok:
            return 0, {"error": message}
        status, payload = wda_request(self.wda_url, method, "/session/%s%s" % (self.session_id, path), body)
        if is_invalid_session(status, payload):
            ok, message = self.ensure_session(force_new=True)
            if not ok:
                return 0, {"error": message}
            status, payload = wda_request(self.wda_url, method, "/session/%s%s" % (self.session_id, path), body)
        return status, payload

    def observe(self, goal: str):
        ok, message = self.ensure_session()
        if not ok:
            return {
                "status": "failed",
                "message": message,
                "wdaSessionId": self.session_id,
            }
        status, payload = self.session_request("GET", "/source")
        source = ""
        if status == 200:
            value = payload.get("value") or payload
            source = value if isinstance(value, str) else json.dumps(value)
        return {
            "status": "completed",
            "message": "Captured developer-device UI.",
            "wdaSessionId": self.session_id,
            "observation": observation_from_source(goal, source, self.session_id),
        }

    def execute(self, action):
        name, payload = parse_action(action)
        ok, message = self.ensure_session()
        if not ok:
            return "failed", message
        if name == "wait":
            seconds = min(max(float(payload.get("seconds") or payload.get("_0") or 1), 0), 30)
            time.sleep(seconds)
            return "completed", "Waited %.1f seconds." % seconds
        if name == "openURL":
            url = payload.get("_0") or payload.get("url") or payload.get("value")
            status, body = self.session_request("POST", "/url", {"url": url})
            if status == 200:
                return "completed", "Opened URL via WDA: %s" % url
            return "failed", body.get("error") or "WDA openURL failed."
        if name in ("tap", "type"):
            control_id = payload.get("controlId") or payload.get("_0")
            label = payload.get("text") if name == "type" else control_id
            status, body = self.session_request(
                "POST",
                "/element",
                {"using": "accessibility id", "value": control_id},
            )
            if status != 200:
                status, body = self.session_request(
                    "POST",
                    "/element",
                    {"using": "name", "value": control_id},
                )
            element = (body.get("value") or body).get("ELEMENT") or (body.get("value") or {}).get("element-6066-11e4-a52e-4f735466cecf")
            if not element:
                return "failed", "Control not found: %s" % control_id
            if name == "tap":
                status, body = self.session_request("POST", "/element/%s/click" % element, {})
                return ("completed", "Tapped %s" % control_id) if status == 200 else ("failed", body.get("error") or "click failed")
            status, body = self.session_request(
                "POST",
                "/element/%s/value" % element,
                {"value": list(str(label or "")), "text": str(label or "")},
            )
            return ("completed", "Typed into %s" % control_id) if status == 200 else ("failed", body.get("error") or "type failed")
        if name == "scroll":
            return "skipped", "Scroll requires a visible element adapter; use tap/type first."
        if name == "handoff":
            return "completed", "WebDriverAgent handoff accepted."
        return "failed", "Unsupported WDA adapter action: %s" % name


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


class Handler(BaseHTTPRequestHandler):
    server_version = "PrivateAgentWDAAdapter/0.1"

    def log_message(self, fmt, *args):
        sys.stdout.write("%s - %s\n" % (self.address_string(), fmt % args))
        sys.stdout.flush()

    def _send_json(self, status, payload):
        data = json.dumps(payload, indent=2, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _authorized(self):
        token = self.server.state.token
        if not token:
            return True
        return self.headers.get("Authorization", "") == "Bearer %s" % token

    def _read_body(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return {}
        return json.loads(self.rfile.read(length).decode("utf-8"))

    def do_GET(self):  # noqa: N802
        if self.path != "/status":
            self._send_json(404, {"error": "not_found"})
            return
        if not self._authorized():
            self._send_json(401, {"error": "unauthorized"})
            return
        ok, message = self.server.state.ensure_session()
        self._send_json(200, {"ready": ok, "message": message, "sessionId": self.server.state.session_id})

    def do_POST(self):  # noqa: N802
        if not self._authorized():
            self._send_json(401, {"error": "unauthorized"})
            return
        try:
            body = self._read_body()
        except Exception as exc:  # noqa: BLE001
            self._send_json(400, {"error": "invalid_json", "message": str(exc)})
            return
        if self.path == "/observation":
            self._send_json(200, self.server.state.observe(body.get("goal", "")))
            return
        if self.path == "/action":
            status, message = self.server.state.execute(body.get("action"))
            self._send_json(200, {"status": status, "message": message, "wdaSessionId": self.server.state.session_id})
            return
        self._send_json(404, {"error": "not_found"})


def main() -> int:
    parser = argparse.ArgumentParser(description="PrivateAgent WebDriverAgent adapter")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8101)
    parser.add_argument("--token", default="")
    parser.add_argument("--wda-url", default="http://127.0.0.1:8100")
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.state = AdapterState(args.token, args.wda_url)
    print("PrivateAgent WDA adapter on http://%s:%s -> %s" % (args.host, args.port, args.wda_url))
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping WDA adapter.")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
