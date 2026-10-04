#!/usr/bin/env python3
"""Local Mac bridge helper for PrivateAgent.

This helper exposes a tiny authenticated HTTP API on the local network:

- GET /health
- POST /observation
- POST /action

It starts in safe stub mode. It does not perform hidden automation. The action
endpoint logs the requested action and returns a skipped response until a concrete
Mac-side adapter is installed.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


def iso_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


class BridgeState:
    def __init__(self, token: str) -> None:
        self.token = token
        self.started_at = iso_now()
        self.events: list[dict[str, Any]] = []

    def record(self, event: dict[str, Any]) -> None:
        event["receivedAt"] = iso_now()
        self.events.append(event)
        self.events = self.events[-100:]
        print(json.dumps(event, sort_keys=True), flush=True)


class Handler(BaseHTTPRequestHandler):
    server_version = "PrivateAgentMacBridge/0.1"

    @property
    def state(self) -> BridgeState:
        return self.server.state  # type: ignore[attr-defined]

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stdout.write("%s - %s\n" % (self.address_string(), fmt % args))
        sys.stdout.flush()

    def _send_json(self, status: int, payload: dict[str, Any]) -> None:
        data = json.dumps(payload, indent=2, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _authorized(self) -> bool:
        header = self.headers.get("Authorization", "")
        return header == f"Bearer {self.state.token}"

    def _read_body(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        return json.loads(raw.decode("utf-8"))

    def do_GET(self) -> None:  # noqa: N802
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
                "mode": "safe-stub",
            },
        )

    def do_POST(self) -> None:  # noqa: N802
        if not self._authorized():
            self._send_json(401, {"error": "unauthorized"})
            return

        try:
            body = self._read_body()
        except Exception as exc:  # pragma: no cover - defensive server path
            self._send_json(400, {"error": "invalid_json", "message": str(exc)})
            return

        if self.path == "/observation":
            self.state.record({"type": "observation", "body": body})
            goal = body.get("goal", "")
            self._send_json(
                200,
                {
                    "status": "completed",
                    "message": "Safe stub observation created. Install a screen adapter to capture live state.",
                    "observation": {
                        "source": "macBridge",
                        "userGoal": goal,
                        "visibleText": ["Mac bridge connected", "Safe stub mode"],
                        "controls": [],
                        "appContext": "Mac bridge helper safe stub",
                        "timestamp": iso_now(),
                    },
                },
            )
            return

        if self.path == "/action":
            self.state.record({"type": "action", "body": body})
            self._send_json(
                200,
                {
                    "status": "skipped",
                    "message": "Mac bridge is connected, but no action adapter is installed yet.",
                },
            )
            return

        self._send_json(404, {"error": "not_found"})


def main() -> int:
    parser = argparse.ArgumentParser(description="PrivateAgent Mac bridge helper")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--token", required=True)
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.state = BridgeState(args.token)  # type: ignore[attr-defined]

    print(f"PrivateAgent Mac Bridge listening on http://{args.host}:{args.port}", flush=True)
    print("Safe stub mode: observation/action requests are logged, not executed.", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping bridge.", flush=True)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
