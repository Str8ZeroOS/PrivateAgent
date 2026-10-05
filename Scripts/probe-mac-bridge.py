#!/usr/bin/env python3
"""Probe a PrivateAgent Mac bridge without touching the iPhone directly."""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request


def load_env_file(path: str) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        with open(path, encoding="utf-8") as handle:
            for raw in handle:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                values[key.strip()] = value.strip()
    except OSError:
        pass
    return values


def request_json(url: str, token: str, method: str = "GET", body: dict | None = None) -> tuple[int, dict]:
    data = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", "Bearer %s" % token)
    if body is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=4) as response:
            payload = json.loads(response.read().decode("utf-8"))
            return response.getcode(), payload
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        try:
            payload = json.loads(raw)
        except Exception:
            payload = {"error": raw}
        return exc.code, payload


def main() -> int:
    parser = argparse.ArgumentParser(description="Probe PrivateAgent Mac bridge health")
    parser.add_argument("--host", default=os.environ.get("PRIVATEAGENT_BRIDGE_HOST", ""))
    parser.add_argument("--port", type=int, default=int(os.environ.get("PRIVATEAGENT_BRIDGE_PORT", "8765")))
    parser.add_argument("--token", default=os.environ.get("PRIVATEAGENT_BRIDGE_TOKEN", ""))
    parser.add_argument("--env-file", default=os.path.expanduser("~/.privateagent/bridge.env"))
    args = parser.parse_args()

    file_values = load_env_file(args.env_file)
    host = args.host or file_values.get("PRIVATEAGENT_BRIDGE_HOST", "")
    token = args.token or file_values.get("PRIVATEAGENT_BRIDGE_TOKEN", "")
    port = args.port
    if file_values.get("PRIVATEAGENT_BRIDGE_PORT") and not args.host:
        try:
            port = int(file_values["PRIVATEAGENT_BRIDGE_PORT"])
        except ValueError:
            port = args.port

    if not host or not token:
        print("No pairing found. Run Scripts/start-mac-bridge.sh on the MacBook.")
        return 2

    health_url = "http://%s:%s/health" % (host, port)
    status, payload = request_json(health_url, token)
    print(json.dumps({"url": health_url, "status": status, "body": payload}, indent=2, sort_keys=True))
    if status != 200:
        return 1

    obs_status, obs = request_json(
        "http://%s:%s/observation" % (host, port),
        token,
        method="POST",
        body={"goal": "Probe iPhone Mirroring observation"},
    )
    print(json.dumps({"observationStatus": obs_status, "observation": obs}, indent=2, sort_keys=True))
    source = ((obs.get("observation") or {}).get("source") if isinstance(obs, dict) else None)
    if source == "iphoneMirroring":
        print("iPhone Mirroring window is frontmost on the Mac helper.")
    else:
        print("Bridge is up. Frontmost app is not classified as iPhone Mirroring yet.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
