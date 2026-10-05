#!/usr/bin/env bash
# Import Apple Distribution .p12 + App Store profile into a temporary keychain.
# Never prints secret values. Writes KEYCHAIN_PATH, PROFILE_NAME, PROFILE_UUID
# to GITHUB_ENV when present. Does not persist the keychain password.
set -euo pipefail

: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"
: "${IOS_DIST_CERT_P12_BASE64:?IOS_DIST_CERT_P12_BASE64 is required}"
: "${IOS_DIST_CERT_PASSWORD:?IOS_DIST_CERT_PASSWORD is required}"
: "${IOS_PROVISIONING_PROFILE_BASE64:?IOS_PROVISIONING_PROFILE_BASE64 is required}"
: "${IOS_BUNDLE_ID:?IOS_BUNDLE_ID is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"

p12="$RUNNER_TEMP/dist.p12"
profile="$RUNNER_TEMP/appstore.mobileprovision"
plist="$RUNNER_TEMP/profile.plist"
keychain="$RUNNER_TEMP/testflight.keychain-db"
keychain_password="$(uuidgen)"

printf '%s' "$IOS_DIST_CERT_P12_BASE64" | base64 --decode > "$p12"
if [[ ! -s "$p12" ]]; then
  echo "::error::IOS_DIST_CERT_P12_BASE64 did not decode to a non-empty .p12. Re-encode the file in PowerShell as documented in Docs/TESTFLIGHT_SETUP.md."
  exit 1
fi

printf '%s' "$IOS_PROVISIONING_PROFILE_BASE64" | base64 --decode > "$profile"
if [[ ! -s "$profile" ]]; then
  echo "::error::IOS_PROVISIONING_PROFILE_BASE64 did not decode to a non-empty .mobileprovision."
  exit 1
fi

echo "::group::Create temporary keychain"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
echo "::endgroup::"

echo "::group::Import Apple Distribution certificate"
if ! security import "$p12" -P "$IOS_DIST_CERT_PASSWORD" -A -t cert -f pkcs12 -k "$keychain" \
  -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/xcodebuild; then
  echo "::error::Could not import the .p12. Check IOS_DIST_CERT_PASSWORD and that the file is an Apple Distribution certificate (OpenSSL 3 may need pkcs12 -legacy)."
  exit 1
fi
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain"
security find-identity -v -p codesigning "$keychain"
echo "::endgroup::"

if ! security find-identity -v -p codesigning "$keychain" | grep -q "Apple Distribution"; then
  echo "::error::The imported .p12 does not contain an Apple Distribution identity. Create an iOS Distribution certificate, not a Development certificate. See Docs/TESTFLIGHT_SETUP.md."
  exit 1
fi

echo "::group::Install App Store provisioning profile"
if ! security cms -D -i "$profile" > "$plist"; then
  echo "::error::The provisioning profile is not valid CMS/plist data. Download an App Store profile, not a Development or Ad Hoc profile."
  exit 1
fi

pb=/usr/libexec/PlistBuddy
uuid="$($pb -c 'Print UUID' "$plist")"
name="$($pb -c 'Print Name' "$plist")"
team="$($pb -c 'Print TeamIdentifier:0' "$plist")"
app_id="$($pb -c 'Print Entitlements:application-identifier' "$plist")"
profile_bundle="${app_id#*.}"

if [[ "$team" != "$APPLE_TEAM_ID" ]]; then
  echo "::error::APPLE_TEAM_ID does not match the provisioning profile team (${team})."
  exit 1
fi
if [[ "$profile_bundle" != "$IOS_BUNDLE_ID" ]]; then
  echo "::error::Bundle id ${IOS_BUNDLE_ID} does not match the provisioning profile (${profile_bundle}). Set repository variable IOS_BUNDLE_ID or recreate the profile."
  exit 1
fi

mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
cp "$profile" "$HOME/Library/MobileDevice/Provisioning Profiles/${uuid}.mobileprovision"
echo "Imported profile '${name}' (${uuid}) for ${profile_bundle} / ${team}"
echo "::endgroup::"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "KEYCHAIN_PATH=${keychain}"
    echo "PROFILE_NAME=${name}"
    echo "PROFILE_UUID=${uuid}"
  } >> "$GITHUB_ENV"
fi

# Drop decoded cert bytes from disk after import. Profile stays until cleanup
# because xcodebuild may re-read it from the MobileDevice directory copy.
rm -f "$p12"
unset IOS_DIST_CERT_P12_BASE64 IOS_DIST_CERT_PASSWORD IOS_PROVISIONING_PROFILE_BASE64 keychain_password
