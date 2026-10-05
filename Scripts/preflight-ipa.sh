#!/usr/bin/env bash
# Local App Store sanity checks on an exported IPA. Never prints secrets.
# Catches icon / plist / architecture issues before altool / TestFlight.
set -euo pipefail

ipa="${1:-${IPA_PATH:-}}"
if [[ -z "$ipa" || ! -f "$ipa" ]]; then
  echo "::error::preflight-ipa: IPA not found (${ipa:-empty})."
  exit 1
fi

marketing="${MARKETING_VERSION:-}"
build="${BUILD_NUMBER:-}"
work="${RUNNER_TEMP:-/tmp}/ipa-preflight"
rm -rf "$work"
mkdir -p "$work"
unzip -qq "$ipa" -d "$work"
app="$(find "$work/Payload" -name '*.app' -type d -print -quit)"
if [[ -z "$app" ]]; then
  echo "::error::preflight-ipa: Payload/*.app missing in $ipa"
  exit 1
fi

plist="$app/Info.plist"
if [[ ! -f "$plist" ]]; then
  echo "::error::preflight-ipa: Info.plist missing"
  exit 1
fi

pb=/usr/libexec/PlistBuddy
need() {
  local key="$1"
  if ! "$pb" -c "Print $key" "$plist" >/dev/null 2>&1; then
    echo "::error::preflight-ipa: Info.plist missing $key"
    exit 1
  fi
}

need CFBundleIconName
need CFBundleDisplayName
need CFBundleName
need UILaunchScreen
need ITSAppUsesNonExemptEncryption
need "UISupportedInterfaceOrientations:0"
need "UISupportedInterfaceOrientations~ipad:3"

icon_name="$("$pb" -c 'Print CFBundleIconName' "$plist")"
if [[ "$icon_name" != "AppIcon" ]]; then
  echo "::error::preflight-ipa: CFBundleIconName is '${icon_name}', expected AppIcon"
  exit 1
fi

display_name="$("$pb" -c 'Print CFBundleDisplayName' "$plist")"
bundle_name="$("$pb" -c 'Print CFBundleName' "$plist")"
if [[ "$display_name" != "Str8ZeRO" || "$bundle_name" != "Str8ZeRO" ]]; then
  echo "::error::preflight-ipa: app name is '${display_name}' / '${bundle_name}', expected Str8ZeRO"
  exit 1
fi

encrypt="$("$pb" -c 'Print ITSAppUsesNonExemptEncryption' "$plist")"
if [[ "$encrypt" != "false" && "$encrypt" != "0" ]]; then
  echo "::error::preflight-ipa: ITSAppUsesNonExemptEncryption must be false"
  exit 1
fi

if [[ -n "$marketing" ]]; then
  short="$("$pb" -c 'Print CFBundleShortVersionString' "$plist")"
  if [[ "$short" != "$marketing" ]]; then
    echo "::error::preflight-ipa: CFBundleShortVersionString is '${short}', expected '${marketing}' from the tag"
    exit 1
  fi
fi
if [[ -n "$build" ]]; then
  ver="$("$pb" -c 'Print CFBundleVersion' "$plist")"
  if [[ "$ver" != "$build" ]]; then
    echo "::error::preflight-ipa: CFBundleVersion is '${ver}', expected '${build}' from the tag"
    exit 1
  fi
fi

if [[ ! -f "$app/PrivacyInfo.xcprivacy" ]]; then
  echo "::error::preflight-ipa: PrivacyInfo.xcprivacy is not in the app bundle"
  exit 1
fi

# Compiled catalog or loose icons — reject a bundle with neither.
if [[ ! -f "$app/Assets.car" ]] && ! find "$app" \( -iname '*AppIcon*' -o -iname '*120*' \) | grep -q .; then
  echo "::error::preflight-ipa: no Assets.car / AppIcon assets in the app bundle"
  exit 1
fi

binary="$app/$(basename "$app" .app)"
if [[ ! -f "$binary" ]]; then
  binary="$(find "$app" -maxdepth 1 -type f -perm -111 | head -1)"
fi
if [[ -n "$binary" && -x /usr/bin/lipo ]]; then
  info="$(lipo -info "$binary" 2>/dev/null || true)"
  echo "Main binary slices: $info"
  if echo "$info" | grep -Eqi 'x86_64|i386|iphonesimulator'; then
    echo "::error::preflight-ipa: app binary contains simulator or Intel slices: $info"
    exit 1
  fi
fi

# Embedded frameworks / dylibs must not be simulator-only.
while IFS= read -r lib; do
  [[ -z "$lib" ]] && continue
  info="$(lipo -info "$lib" 2>/dev/null || true)"
  if echo "$info" | grep -Eqi 'x86_64|i386|iphonesimulator'; then
    echo "::error::preflight-ipa: embedded binary has simulator/Intel slices: $lib ($info)"
    exit 1
  fi
done < <(find "$app" \( -name '*.dylib' -o -name '*.framework' \) -print)

echo "IPA preflight passed for $(basename "$ipa")"
echo "  CFBundleIconName=AppIcon  version=${marketing:-?} (${build:-?})"
echo "  UILaunchScreen present  ITSAppUsesNonExemptEncryption=false  iPad orientations=4"
