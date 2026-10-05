#!/usr/bin/env python3
"""Write ExportOptions.plist for an App Store Connect / TestFlight IPA."""

from __future__ import annotations

import os
import plistlib
import sys


def require(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        print(f"::error::Missing {name} while writing ExportOptions.plist.", file=sys.stderr)
        raise SystemExit(1)
    return value


def main() -> None:
    team_id = require("APPLE_TEAM_ID")
    bundle_id = require("IOS_BUNDLE_ID")
    profile_name = require("PROFILE_NAME")
    runner_temp = require("RUNNER_TEMP")
    path = os.path.join(runner_temp, "ExportOptions.plist")
    options = {
        "method": "app-store-connect",
        "destination": "export",
        "teamID": team_id,
        "signingStyle": "manual",
        "signingCertificate": "Apple Distribution",
        "provisioningProfiles": {bundle_id: profile_name},
        "uploadSymbols": True,
        "compileBitcode": False,
    }
    with open(path, "wb") as handle:
        plistlib.dump(options, handle)
    print(f"Wrote {path}")


if __name__ == "__main__":
    main()
