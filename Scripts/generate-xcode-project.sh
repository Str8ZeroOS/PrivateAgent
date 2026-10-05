#!/usr/bin/env bash
# Generate PrivateAgent.xcodeproj from project.yml. Never prints secrets.
set -euo pipefail

if ! command -v xcodegen >/dev/null; then
  echo "::error::xcodegen is not installed. The workflow should brew-install it before this step."
  exit 1
fi

echo "::group::xcodegen --version"
xcodegen --version
echo "::endgroup::"

echo "::group::xcodegen generate"
if ! xcodegen generate; then
  echo "::error::xcodegen failed to parse project.yml. Check source paths and Apps/PrivateAgentiOS/Info.plist. See Docs/TESTFLIGHT_SETUP.md."
  exit 1
fi
echo "::endgroup::"

if [[ ! -d PrivateAgent.xcodeproj ]]; then
  echo "::error::xcodegen did not create PrivateAgent.xcodeproj."
  exit 1
fi

if ! grep -q 'PRODUCT_NAME = Str8ZeRO' PrivateAgent.xcodeproj/project.pbxproj; then
  echo "::error::Generated project is missing PRODUCT_NAME = Str8ZeRO (CFBundleName follows PRODUCT_NAME)."
  exit 1
fi

echo "::group::xcodebuild -list"
xcodebuild -list -project PrivateAgent.xcodeproj
echo "::endgroup::"
