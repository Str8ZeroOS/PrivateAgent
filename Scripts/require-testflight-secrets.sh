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
echo "Signed TestFlight upload needs App Store signing material."
echo "Add the secrets at: Settings → Secrets and variables → Actions."
echo "Windows / no-Mac steps: Docs/TESTFLIGHT_SETUP.md"
echo
echo "Required secrets:"
printf '  - %s\n' "${required[@]}"
echo
echo "Optional repository variable:"
echo "  - IOS_BUNDLE_ID (defaults to com.privateagent.ios)"
echo
echo "Then ship with: git tag v1.0.0 && git push origin v1.0.0"
exit 1
