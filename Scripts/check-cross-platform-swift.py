#!/usr/bin/env python3
"""Fail fast on platform-specific SwiftUI APIs in cross-platform package sources.

SwiftPM builds PrivateAgentUI for macOS in CI. Some modifiers are valid on iOS
but unavailable in macOS package builds. This scanner catches the common cases
before the slower Swift build reaches them.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCAN_ROOTS = [ROOT / "Sources" / "PrivateAgentUI"]

BANNED_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\.textInputAutocapitalization\s*\("), "iOS-only SwiftUI modifier; use a cross-platform field or wrap in #if os(iOS)."),
    (re.compile(r"\.keyboardType\s*\("), "UIKit/iOS keyboard modifier; wrap in #if os(iOS) or omit from cross-platform SwiftPM views."),
    (re.compile(r"ToolbarItem\s*\(\s*placement:\s*\.topBar(Leading|Trailing)\s*\)"), "iOS-only toolbar placement in macOS SwiftPM build; use default ToolbarItem placement or conditional code."),
]

ALLOW_MARKER = "cross-platform-check: allow"


def iter_swift_files() -> list[pathlib.Path]:
    files: list[pathlib.Path] = []
    for root in SCAN_ROOTS:
        if root.exists():
            files.extend(sorted(root.rglob("*.swift")))
    return files


def main() -> int:
    failures: list[str] = []
    for path in iter_swift_files():
        rel = path.relative_to(ROOT)
        lines = path.read_text(encoding="utf-8").splitlines()
        for number, line in enumerate(lines, start=1):
            if ALLOW_MARKER in line:
                continue
            for pattern, message in BANNED_PATTERNS:
                if pattern.search(line):
                    failures.append(f"{rel}:{number}: {message}\n    {line.strip()}")

    if failures:
        print("Cross-platform Swift preflight failed:\n", file=sys.stderr)
        print("\n".join(failures), file=sys.stderr)
        print("\nAdd explicit platform conditionals or remove the iOS-only API.", file=sys.stderr)
        return 1

    print("Cross-platform Swift preflight passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
