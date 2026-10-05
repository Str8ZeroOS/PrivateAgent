#!/usr/bin/env bash
# Fail with a readable list of missing TestFlight secrets. Never prints values.
set -euo pipefail

required=(
  APPLE_TEAM_ID
  IOS_DIST_CERT_P12_BASE64
  IOS_DIST_CERT_PASSWORD
  IOS_PROVISIONING_PROFILE_BASE64
  ASC_KEY_ID
  ASC_ISSUER_ID
  ASC_KEY_P8_BASE64
)

missing=()
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    missing+=("${name}")
  fi
done

if [[ ${#missing[@]} -eq 0 ]]; then
  echo "All required TestFlight secrets are present."
  exit 0
fi

echo "::error::Missing GitHub secrets: ${missing[*]}"
echo
echo "This job signs an App Store IPA and uploads it to TestFlight."
echo "Add the secrets in the GitHub repo: Settings → Secrets and variables → Actions."
echo "Step-by-step (Windows, no Mac): Docs/TESTFLIGHT_SETUP.md"
echo
echo "Required secrets:"
printf '  - %s\n' "${required[@]}"
echo
echo "Optional repository variable:"
echo "  - IOS_BUNDLE_ID (defaults to com.privateagent.ios)"
exit 1
