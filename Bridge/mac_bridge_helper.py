#!/usr/bin/env python
"""Local Mac bridge helper for PrivateAgent.

This helper exposes a small authenticated HTTP API on the local network:

- GET /health
- POST /observation
- POST /action
- POST /pair   (unauthenticated; exchanges a one-time pairing code for a token)

Pairing: on start the helper prints a 6-digit one-time pairing code (it
rotates every few minutes). In Str8ZeRO > Agent Mode > Mac Bridge, tap
"Check Bridge", type the code and tap "Pair". The app POSTs the code to /pair
and receives a random bearer token, which it keeps in the iOS Keychain. Only a
SHA-256 hash of each issued token is stored on this computer, and tokens are
never printed. Wrong codes are rate limited (a code dies after 5 misses and
pairing locks after 15 misses until restart).

It runs on macOS (including old Python 2.7 installs) and on Windows/Linux,
where the Mac-only actions report themselves as unavailable.

Low-risk Mac actions are enabled by default. Privacy-sensitive observation and
UI-control actions require explicit launch flags so the bridge can move toward
Android-like behavior without silently expanding authority.

The script supports both Python 2.7 on older macOS installs and Python 3.x on
newer machines.
"""

from __future__ import print_function

import argparse
import binascii
import hashlib
import hmac
import json
import os
import platform
import random
import socket
import subprocess
import sys
import threading
import time
import webbrowser

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

IPHONE_MIRRORING_MARKERS = (
    "iphone mirroring",
)

IS_MAC = sys.platform == "darwin"

try:  # Python 2: JSON strings arrive as unicode
    TEXT_TYPES = (str, unicode)  # noqa: F821
except NameError:  # Python 3
    TEXT_TYPES = (str,)
DEFAULT_PAIRING_TTL = 300
MAX_ATTEMPTS_PER_CODE = 5
MAX_TOTAL_PAIRING_FAILURES = 15
MAX_BODY_BYTES = 256 * 1024


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
    if not IS_MAC:
        return "unavailable on %s" % platform.system()
    ok, out, err = run_osascript('tell application "System Events" to get name of first process whose frontmost is true')
    if ok and out:
        return out
    return "unknown (%s)" % err if err else "unknown"


def is_iphone_mirroring_app(name):
    lowered = (name or "").lower()
    for marker in IPHONE_MIRRORING_MARKERS:
        if marker in lowered:
            return True
    return False


def observation_source(app_name, mirroring_enabled):
    if mirroring_enabled and is_iphone_mirroring_app(app_name):
        return "iphoneMirroring"
    return "macBridge"


def ax_element_names():
    app = apple_string(frontmost_app())
    script = 'tell application "System Events" to tell process "%s" to get name of every UI element of window 1' % app
    ok, out, err = run_osascript(script, timeout=6)
    if not ok or not out:
        return [], err or "Accessibility observation unavailable."
    names = []
    for part in out.split(","):
        name = part.strip()
        if name and name != "missing value" and name not in names:
            names.append(name)
    return names[:40], None


def ax_controls():
    names, err = ax_element_names()
    controls = []
    for index, name in enumerate(names):
        controls.append({
            "id": "ax-%d" % index,
            "label": name,
            "role": "unknown",
            "isEnabled": True,
        })
    return controls, err


def tap_ax(control_id):
    names, err = ax_element_names()
    if err and not names:
        return "failed", "No AX controls: %s" % err
    target = None
    if isinstance(control_id, str) and control_id.startswith("ax-"):
        try:
            index = int(control_id.split("-", 1)[1])
            if 0 <= index < len(names):
                target = names[index]
        except Exception:
            target = None
    if target is None:
        lowered = str(control_id or "").lower()
        for name in names:
            if name.lower() == lowered or lowered in name.lower():
                target = name
                break
    if target is None:
        return "failed", "Control not found: %s" % control_id
    app = apple_string(frontmost_app())
    script = 'tell application "System Events" to tell process "%s" to click UI element "%s" of window 1' % (
        app,
        apple_string(target),
    )
    ok, _, click_err = run_osascript(script, timeout=6)
    if ok:
        return "completed", "Clicked AX control %s" % target
    return "failed", "AX click failed. Grant Accessibility permission: %s" % click_err


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
    if not IS_MAC:
        try:
            if webbrowser.open(url):
                return "completed", "Opened URL on %s: %s" % (platform.system(), url)
        except Exception as exc:
            return "failed", "Failed to open URL: %s" % exc
        return "failed", "No browser available to open URL."
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
        if not state.enable_accessibility_actions:
            return "skipped", "Tap requires --enable-accessibility-actions."
        return tap_ax(payload.get("controlId") or payload.get("_0"))
    if name == "runShortcut":
        return "failed", "Shortcuts CLI is not available on this macOS version."
    return "failed", "Unsupported bridge action: %s" % name


def to_bytes(value):
    if isinstance(value, bytes):
        return value
    return value.encode("utf-8")


def constant_time_equals(left, right):
    if not isinstance(left, TEXT_TYPES + (bytes,)) or not isinstance(right, TEXT_TYPES + (bytes,)):
        return False
    try:
        left_bytes = to_bytes(left)
        right_bytes = to_bytes(right)
    except Exception:
        return False
    compare = getattr(hmac, "compare_digest", None)
    if compare is not None:
        return compare(left_bytes, right_bytes)
    if len(left_bytes) != len(right_bytes):
        return False
    result = 0
    for a, b in zip(bytearray(left_bytes), bytearray(right_bytes)):
        result |= a ^ b
    return result == 0


def new_token():
    return str(binascii.hexlify(os.urandom(32)).decode("ascii"))


def token_hash(token):
    return str(hashlib.sha256(to_bytes(token)).hexdigest())


def redact(secret):
    if not secret:
        return "<none>"
    return "****%s (%d chars)" % (secret[-4:], len(secret)) if len(secret) > 8 else "****"


def lan_ip_guess():
    """Best-effort LAN address (no packets are sent)."""
    sock = None
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.connect(("10.255.255.255", 1))
        return sock.getsockname()[0]
    except Exception:
        return None
    finally:
        if sock is not None:
            sock.close()


def default_state_dir():
    return os.path.join(os.path.expanduser("~"), ".privateagent")


class PairingManager(object):
    """One-time pairing codes -> random bearer tokens.

    Only SHA-256 hashes of issued tokens are persisted. Codes are 6 digits,
    single use, expire after `ttl` seconds, and are rate limited.
    """

    def __init__(self, enabled=True, state_path=None, ttl=DEFAULT_PAIRING_TTL,
                 printer=None, clock=time.time, advertise=None):
        self.enabled = enabled
        self.state_path = state_path
        self.ttl = max(int(ttl), 30)
        self.printer = printer or (lambda line: (print(line), sys.stdout.flush()))
        self.clock = clock
        self.advertise = advertise  # (host, port) for the deep link, or None
        self.lock = threading.Lock()
        self.devices = self._load()
        self.code = None
        self.expires_at = 0
        self.attempts = 0
        self.total_failures = 0
        self.locked = False
        self._rng = random.SystemRandom()
        if self.enabled:
            self._rotate_locked("start")

    # -- persistence ---------------------------------------------------
    def _load(self):
        if not self.state_path or not os.path.exists(self.state_path):
            return []
        try:
            with open(self.state_path, "r") as handle:
                data = json.load(handle)
            devices = data.get("devices") or []
            return [d for d in devices if isinstance(d, dict) and d.get("tokenSha256")]
        except Exception:
            return []

    def _save(self):
        if not self.state_path:
            return
        directory = os.path.dirname(self.state_path)
        if directory and not os.path.isdir(directory):
            os.makedirs(directory)
        tmp = self.state_path + ".tmp"
        with open(tmp, "w") as handle:
            json.dump({"devices": self.devices}, handle, indent=2, sort_keys=True)
        try:
            os.chmod(tmp, 0o600)
        except Exception:
            pass
        replace = getattr(os, "replace", None)
        if replace is not None:
            replace(tmp, self.state_path)
        else:  # Python 2 (macOS): rename overwrites atomically on POSIX
            os.rename(tmp, self.state_path)

    def forget_all(self):
        with self.lock:
            self.devices = []
            self._save()

    # -- codes -----------------------------------------------------------
    def _rotate_locked(self, reason):
        self.code = "%06d" % self._rng.randint(0, 999999)
        self.expires_at = self.clock() + self.ttl
        self.attempts = 0
        self._announce(reason)

    def _announce(self, reason):
        pretty = "%s %s" % (self.code[:3], self.code[3:])
        minutes = max(1, int(round(self.ttl / 60.0)))
        lines = [
            "",
            "=" * 60,
            "  Str8ZeRO pairing code: %s   (valid %d min, one use)" % (pretty, minutes),
            "  iPhone: Agent Mode > Mac Bridge > Check Bridge > enter code > Pair",
        ]
        if self.advertise:
            lines.append("  Or open on the iPhone: privateagent://pair?host=%s&port=%s&code=%s"
                         % (self.advertise[0], self.advertise[1], self.code))
        if reason == "expired":
            lines.append("  (previous code expired)")
        elif reason == "too_many_attempts":
            lines.append("  (previous code was retired after too many wrong attempts)")
        elif reason == "paired":
            lines.append("  (previous code was used; this one is for another device)")
        lines.append("=" * 60)
        for line in lines:
            self.printer(line)

    def tick(self):
        with self.lock:
            if self.enabled and not self.locked and self.clock() >= self.expires_at:
                self._rotate_locked("expired")

    def status(self):
        if not self.enabled:
            return "disabled"
        if self.locked:
            return "locked"
        return "available"

    def attempt(self, code, device_name, remote=None):
        """Returns (http_status, payload)."""
        with self.lock:
            if not self.enabled:
                return 403, {"error": "pairing_disabled"}
            if self.locked:
                return 429, {"error": "pairing_locked"}
            if not isinstance(code, TEXT_TYPES) or len(code) != 6 or not all(c in "0123456789" for c in code):
                return 400, {"error": "invalid_request", "message": "code must be 6 digits"}
            if self.clock() >= self.expires_at:
                self._rotate_locked("expired")
                return 410, {"error": "code_expired"}
            if not constant_time_equals(code, self.code):
                self.attempts += 1
                self.total_failures += 1
                if self.total_failures >= MAX_TOTAL_PAIRING_FAILURES:
                    self.locked = True
                    self.printer("Pairing LOCKED after %d wrong codes (last from %s). Restart the bridge to pair again."
                                 % (self.total_failures, remote or "unknown"))
                    return 429, {"error": "pairing_locked"}
                remaining = MAX_ATTEMPTS_PER_CODE - self.attempts
                if remaining <= 0:
                    self._rotate_locked("too_many_attempts")
                    remaining = 0
                self.printer("Wrong pairing code from %s." % (remote or "unknown"))
                return 403, {"error": "invalid_code", "attemptsRemaining": remaining}

            token = new_token()
            name = device_name if isinstance(device_name, TEXT_TYPES) and device_name else "iPhone"
            name = name[:64]
            printable = name.encode("ascii", "replace").decode("ascii")
            self.devices.append({
                "tokenSha256": token_hash(token),
                "deviceName": name,
                "pairedAt": iso_now(),
            })
            self.devices = self.devices[-20:]
            try:
                self._save()
            except Exception as exc:
                self.printer("Warning: could not save paired devices: %s" % exc)
            self.printer("Paired with '%s' from %s." % (printable, remote or "unknown"))
            self._rotate_locked("paired")
            return 200, {"token": token, "service": "PrivateAgent Mac Bridge", "deviceName": name}

    def is_authorized_token(self, token):
        if not token:
            return False
        try:
            digest = token_hash(token)
        except Exception:
            return False
        with self.lock:
            devices = list(self.devices)
        matched = False
        for device in devices:
            if constant_time_equals(digest, device.get("tokenSha256", "")):
                matched = True
        return matched

    def start_rotation_thread(self):
        if not self.enabled:
            return None

        def loop():
            while True:
                time.sleep(1)
                try:
                    self.tick()
                except Exception:
                    pass

        thread = threading.Thread(target=loop, name="pairing-rotation")
        thread.daemon = True
        thread.start()
        return thread


class BridgeState(object):
    def __init__(
        self,
        token,
        enable_accessibility_actions=False,
        enable_clipboard_observation=False,
        enable_ax_observation=False,
        enable_iphone_mirroring=False,
        pairing=None,
    ):
        self.token = token or ""
        self.pairing = pairing or PairingManager(enabled=False)
        self.enable_accessibility_actions = enable_accessibility_actions
        self.enable_clipboard_observation = enable_clipboard_observation
        self.enable_ax_observation = enable_ax_observation
        self.enable_iphone_mirroring = enable_iphone_mirroring
        self.started_at = iso_now()
        self.events = []

    def capabilities(self):
        result = [
            "health",
            "pairing",
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
        if self.enable_ax_observation:
            result.append("axTreeObservation")
        if self.enable_accessibility_actions:
            result.append("axClick")
        if self.enable_iphone_mirroring:
            result.append("iphoneMirroringObservation")
        return result

    def mode(self):
        flags = []
        if self.enable_accessibility_actions:
            flags.append("accessibility")
        if self.enable_clipboard_observation:
            flags.append("clipboard")
        if self.enable_ax_observation:
            flags.append("ax")
        if self.enable_iphone_mirroring:
            flags.append("mirroring")
        if not flags:
            return "guarded-actions"
        return "guarded-actions+" + "+".join(flags)

    def is_authorized(self, header):
        if not isinstance(header, TEXT_TYPES) or not header.startswith("Bearer "):
            return False
        presented = header[len("Bearer "):].strip()
        if not presented:
            return False
        if self.token and constant_time_equals(presented, self.token):
            return True
        return self.pairing.is_authorized_token(presented)

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
        return self.state.is_authorized(self.headers.get("Authorization", ""))

    def _send_unauthorized(self):
        header = self.headers.get("Authorization", "")
        reason = "invalid_token" if header else "missing_token"
        self._send_json(401, {
            "error": "unauthorized",
            "reason": reason,
            "pairing": self.state.pairing.status(),
        })

    def _read_body(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return {}
        if length > MAX_BODY_BYTES:
            raise ValueError("request body too large")
        raw = self.rfile.read(length)
        if not isinstance(raw, str):
            raw = raw.decode("utf-8")
        return json.loads(raw)

    def do_GET(self):  # noqa: N802
        if self.path != "/health":
            self._send_json(404, {"error": "not_found"})
            return
        if not self._authorized():
            self._send_unauthorized()
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
        if self.path == "/pair":
            try:
                body = self._read_body()
            except Exception:
                self._send_json(400, {"error": "invalid_request"})
                return
            if not isinstance(body, dict):
                body = {}
            code = body.get("code")
            if code is not None and not isinstance(code, TEXT_TYPES):
                code = None
            status, payload = self.state.pairing.attempt(
                code,
                body.get("deviceName"),
                remote=self.client_address[0] if self.client_address else None,
            )
            self._send_json(status, payload)
            return

        if not self._authorized():
            self._send_unauthorized()
            return

        try:
            body = self._read_body()
        except Exception as exc:
            self._send_json(400, {"error": "invalid_json", "message": str(exc)})
            return

        if self.path == "/observation":
            self.state.record({"type": "observation", "body": body})
            goal = body.get("goal", "")
            app_name = frontmost_app()
            source = observation_source(app_name, self.state.enable_iphone_mirroring)
            visible_text = [
                "Mac bridge connected",
                "Frontmost app: %s" % app_name,
            ]
            if source == "iphoneMirroring":
                visible_text.append("iPhone Mirroring window is frontmost")
                visible_text.append(
                    "This is Mac-side AX of the mirrored window, not an iOS AccessibilityService."
                )
                if not self.state.enable_ax_observation:
                    visible_text.append(
                        "Enable --enable-ax-observation to scrape mirrored window AX names."
                    )
            clip = clipboard_summary(self.state.enable_clipboard_observation)
            if clip:
                visible_text.append(clip)
            controls = []
            if self.state.enable_ax_observation:
                controls, ax_err = ax_controls()
                visible_text.extend([control["label"] for control in controls[:12]])
                if ax_err and not controls:
                    visible_text.append(ax_err)
            app_context = "Mac bridge helper on %s" % platform.node()
            if source == "iphoneMirroring":
                app_context = "iPhone Mirroring on %s" % platform.node()
            self._send_json(
                200,
                {
                    "status": "completed",
                    "message": "Captured Mac bridge context.",
                    "observation": {
                        "source": source,
                        "userGoal": goal,
                        "visibleText": visible_text,
                        "controls": controls,
                        "appContext": app_context,
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
    parser.add_argument("--token", default=os.environ.get("PRIVATEAGENT_BRIDGE_TOKEN", ""),
                        help="Optional legacy static token. Prefer pairing codes.")
    parser.add_argument("--no-pairing", action="store_true", help="Disable /pair (only the static --token works).")
    parser.add_argument("--pairing-ttl", type=int, default=DEFAULT_PAIRING_TTL, help="Seconds each pairing code stays valid.")
    parser.add_argument("--state-dir", default=default_state_dir(), help="Where paired-device token hashes are stored.")
    parser.add_argument("--forget-devices", action="store_true", help="Revoke every paired device before starting.")
    parser.add_argument("--advertise-host", default=None, help="LAN IP to show in the pairing link (auto-detected).")
    parser.add_argument("--enable-accessibility-actions", action="store_true")
    parser.add_argument("--enable-clipboard-observation", action="store_true")
    parser.add_argument("--enable-ax-observation", action="store_true")
    parser.add_argument("--enable-iphone-mirroring", action="store_true")
    args = parser.parse_args()

    if args.no_pairing and not args.token:
        parser.error("--no-pairing needs --token, otherwise nothing could ever authenticate.")

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    advertise_host = args.advertise_host
    if not advertise_host:
        advertise_host = args.host if args.host not in ("0.0.0.0", "") else lan_ip_guess()

    print("PrivateAgent Mac Bridge listening on http://%s:%s" % (args.host, args.port))
    if advertise_host:
        print("iPhone should use Host %s, Port %s" % (advertise_host, args.port))
    sys.stdout.flush()

    state_path = os.path.join(args.state_dir, "bridge_devices.json")
    pairing = PairingManager(
        enabled=not args.no_pairing,
        state_path=state_path,
        ttl=args.pairing_ttl,
        advertise=(advertise_host, args.port) if advertise_host else None,
    )
    if args.forget_devices:
        pairing.forget_all()
        print("Forgot all paired devices.")
    elif pairing.devices:
        print("%d paired device(s) remembered in %s" % (len(pairing.devices), state_path))
    if args.token:
        print("Legacy static token enabled: %s" % redact(args.token))

    server.state = BridgeState(
        args.token,
        enable_accessibility_actions=args.enable_accessibility_actions,
        enable_clipboard_observation=args.enable_clipboard_observation,
        enable_ax_observation=args.enable_ax_observation,
        enable_iphone_mirroring=args.enable_iphone_mirroring,
        pairing=pairing,
    )
    pairing.start_rotation_thread()

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
