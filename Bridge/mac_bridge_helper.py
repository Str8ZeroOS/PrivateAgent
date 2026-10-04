#!/usr/bin/env python
"""Local Mac bridge helper for PrivateAgent.

This helper exposes a small authenticated HTTP API on the local network:

- GET /health
- POST /observation
- POST /action

Low-risk Mac actions are enabled by default. Privacy-sensitive observation and
UI-control actions require explicit launch flags so the bridge can move toward
Android-like behavior without silently expanding authority.

The script supports both Python 2.7 on older macOS installs and Python 3.x on
newer machines.
"""

from __future__ import print_function

import argparse
import json
import platform
import subprocess
import sys
import time

try:  # Python 3
    from http.server import BaseHTTPRequestHandler, HTTPServer
    from socketserver import ThreadingMixIn
except ImportError:  # Python 2.7 on older macOS
    from BaseHTTPServer import BaseHTTPRequestHandler, HTTPServer
    from SocketServer import ThreadingMixIn


SAFE_APP_NAMES = set([
    "Calendar",
    "Contacts",
    "Finder",
    "Mail",
    "Maps",
    "Messages",
    "Notes",
    "Reminders",
    "Safari",
    "System Preferences",
    "TextEdit",
])

SCROLL_KEY_CODES = {
    "up": 126,
    "down": 125,
    "left": 123,
    "right": 124,
}


def iso_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def run_command(args, timeout=10):
    try:
        proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        started = time.time()
        while proc.poll() is None:
            if time.time() - started > timeout:
                proc.kill()
                return False, "", "timed out"
            time.sleep(0.05)
        stdout, stderr = proc.communicate()
        if not isinstance(stdout, str):
            stdout = stdout.decode("utf-8", "replace")
        if not isinstance(stderr, str):
            stderr = stderr.decode("utf-8", "replace")
        return proc.returncode == 0, stdout.strip(), stderr.strip()
    except OSError as exc:
        return False, "", str(exc)


def run_osascript(script, timeout=10):
    return run_command(["/usr/bin/osascript", "-e", script], timeout=timeout)


def apple_string(value):
    if not isinstance(value, str):
        value = str(value)
    return value.replace('\\', '\\\\').replace('"', '\\"')


def frontmost_app():
    ok, out, err = run_osascript('tell application "System Events" to get name of first process whose frontmost is true')
    if ok and out:
        return out
    return "unknown (%s)" % err if err else "unknown"


def clipboard_summary(enabled):
    if not enabled:
        return None
    ok, out, _ = run_command(["/usr/bin/pbpaste"], timeout=2)
    if not ok or not out:
        return "Clipboard empty or unavailable"
    normalized = " ".join(out.split())
    if len(normalized) > 120:
        normalized = normalized[:117] + "..."
    return "Clipboard text: %s" % normalized


def open_url(url):
    if not isinstance(url, str) or not (url.startswith("http://") or url.startswith("https://")):
        return "failed", "Refused URL; only http:// and https:// links are allowed."
    ok, _, err = run_command(["/usr/bin/open", url], timeout=5)
    if ok:
        return "completed", "Opened URL on Mac: %s" % url
    return "failed", "Failed to open URL: %s" % err


def open_app(name):
    if not isinstance(name, str) or name not in SAFE_APP_NAMES:
        return "failed", "Refused app launch; app is not in the bridge allowlist."
    ok, _, err = run_command(["/usr/bin/open", "-a", name], timeout=5)
    if ok:
        return "completed", "Opened app on Mac: %s" % name
    return "failed", "Failed to open app: %s" % err


def type_text(text):
    if not isinstance(text, str):
        return "failed", "Missing text to type."
    if len(text) > 500:
        return "failed", "Refused to type more than 500 characters."
    ok, _, err = run_osascript('tell application "System Events" to keystroke "%s"' % apple_string(text), timeout=5)
    if ok:
        return "completed", "Typed text into the frontmost Mac app."
    return "failed", "Failed to type text. Grant Accessibility permission to Terminal or Python: %s" % err


def key_code(code):
    try:
        value = int(code)
    except Exception:
        return "failed", "Missing numeric key code."
    ok, _, err = run_osascript('tell application "System Events" to key code %d' % value, timeout=5)
    if ok:
        return "completed", "Sent key code %d to the frontmost Mac app." % value
    return "failed", "Failed to send key code. Grant Accessibility permission to Terminal or Python: %s" % err


def scroll(direction):
    code = SCROLL_KEY_CODES.get(str(direction or "").lower())
    if code is None:
        return "failed", "Scroll direction must be up, down, left, or right."
    return key_code(code)


def parse_action(action):
    if not isinstance(action, dict) or not action:
        return None, {}
    name = list(action.keys())[0]
    payload = action.get(name)
    if payload is None:
        payload = {}
    if not isinstance(payload, dict):
        payload = {"value": payload}
    return name, payload


def execute_action(action, state):
    name, payload = parse_action(action)
    if name == "openURL":
        return open_url(payload.get("_0") or payload.get("url") or payload.get("value"))
    if name == "wait":
        seconds = payload.get("seconds") or payload.get("_0") or 1
        try:
            seconds = min(max(float(seconds), 0), 30)
        except Exception:
            seconds = 1
        time.sleep(seconds)
        return "completed", "Waited %.1f seconds." % seconds
    if name == "handoff":
        reason = payload.get("reason") or payload.get("_0") or "No handoff reason provided."
        return "skipped", "Handoff logged for Mac-assisted workflow: %s" % reason
    if name == "openApp":
        return open_app(payload.get("name") or payload.get("_0"))
    if name == "type":
        if not state.enable_accessibility_actions:
            return "skipped", "Typing requires --enable-accessibility-actions."
        return type_text(payload.get("text") or payload.get("_1") or "")
    if name == "scroll":
        if not state.enable_accessibility_actions:
            return "skipped", "Scrolling requires --enable-accessibility-actions."
        return scroll(payload.get("direction") or payload.get("_0"))
    if name == "keyCode":
        if not state.enable_accessibility_actions:
            return "skipped", "Key codes require --enable-accessibility-actions."
        return key_code(payload.get("code") or payload.get("_0"))
    if name == "tap":
        return "skipped", "Tap still requires a coordinate/control adapter; current bridge supports keyboard-style accessibility actions only."
    if name == "runShortcut":
        return "failed", "Shortcuts CLI is not available on this macOS version."
    return "failed", "Unsupported bridge action: %s" % name


class BridgeState(object):
    def __init__(self, token, enable_accessibility_actions=False, enable_clipboard_observation=False):
        self.token = token
        self.enable_accessibility_actions = enable_accessibility_actions
        self.enable_clipboard_observation = enable_clipboard_observation
        self.started_at = iso_now()
        self.events = []

    def capabilities(self):
        result = [
            "health",
            "frontmostAppObservation",
            "openURL",
            "openAllowlistedMacApp",
            "wait",
            "actionAuditLog",
        ]
        if self.enable_accessibility_actions:
            result.extend(["typeText", "sendKeyCode", "scrollByArrowKey"])
        if self.enable_clipboard_observation:
            result.append("clipboardSummaryObservation")
        return result

    def mode(self):
        flags = []
        if self.enable_accessibility_actions:
            flags.append("accessibility")
        if self.enable_clipboard_observation:
            flags.append("clipboard")
        if not flags:
            return "guarded-actions"
        return "guarded-actions+" + "+".join(flags)

    def record(self, event):
        event["receivedAt"] = iso_now()
        self.events.append(event)
        self.events = self.events[-100:]
        print(json.dumps(event, sort_keys=True))
        sys.stdout.flush()


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


class Handler(BaseHTTPRequestHandler):
    server_version = "PrivateAgentMacBridge/0.3"

    @property
    def state(self):
        return self.server.state

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
        header = self.headers.get("Authorization", "")
        return header == "Bearer %s" % self.state.token

    def _read_body(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        if not isinstance(raw, str):
            raw = raw.decode("utf-8")
        return json.loads(raw)

    def do_GET(self):  # noqa: N802
        if self.path != "/health":
            self._send_json(404, {"error": "not_found"})
            return
        if not self._authorized():
            self._send_json(401, {"error": "unauthorized"})
            return
        self._send_json(
            200,
            {
                "status": "ok",
                "service": "PrivateAgent Mac Bridge",
                "startedAt": self.state.started_at,
                "time": iso_now(),
                "mode": self.state.mode(),
                "host": platform.node(),
                "platform": platform.platform(),
                "frontmostApp": frontmost_app(),
                "capabilities": self.state.capabilities(),
            },
        )

    def do_POST(self):  # noqa: N802
        if not self._authorized():
            self._send_json(401, {"error": "unauthorized"})
            return

        try:
            body = self._read_body()
        except Exception as exc:
            self._send_json(400, {"error": "invalid_json", "message": str(exc)})
            return

        if self.path == "/observation":
            self.state.record({"type": "observation", "body": body})
            goal = body.get("goal", "")
            visible_text = [
                "Mac bridge connected",
                "Frontmost app: %s" % frontmost_app(),
            ]
            clip = clipboard_summary(self.state.enable_clipboard_observation)
            if clip:
                visible_text.append(clip)
            self._send_json(
                200,
                {
                    "status": "completed",
                    "message": "Captured Mac bridge context.",
                    "observation": {
                        "source": "macBridge",
                        "userGoal": goal,
                        "visibleText": visible_text,
                        "controls": [],
                        "appContext": "Mac bridge helper on %s" % platform.node(),
                        "timestamp": iso_now(),
                    },
                },
            )
            return

        if self.path == "/action":
            self.state.record({"type": "action", "body": body})
            status, message = execute_action(body.get("action"), self.state)
            self._send_json(200, {"status": status, "message": message})
            return

        self._send_json(404, {"error": "not_found"})


def main():
    parser = argparse.ArgumentParser(description="PrivateAgent Mac bridge helper")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--token", required=True)
    parser.add_argument("--enable-accessibility-actions", action="store_true")
    parser.add_argument("--enable-clipboard-observation", action="store_true")
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.state = BridgeState(
        args.token,
        enable_accessibility_actions=args.enable_accessibility_actions,
        enable_clipboard_observation=args.enable_clipboard_observation,
    )

    print("PrivateAgent Mac Bridge listening on http://%s:%s" % (args.host, args.port))
    print("Mode: %s" % server.state.mode())
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping bridge.")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
