# TestFlight setup from Windows (no Mac)

PrivateAgent is built in GitHub Actions on a **pinned** hosted macOS runner (`macos-15`, Xcode **26.3**) that supports Swift 6. A Mac OS X 10.12.6 machine cannot run that toolchain or iPhone Mirroring. You do **not** need a modern Mac to ship a TestFlight build.

The workflow is `.github/workflows/ios-testflight.yml`.

| Job | When it runs | Secrets |
| --- | --- | --- |
| **Resolve version** | Every run | None |
| **Unsigned iOS simulator build** | Every push and pull request, and before a release | None |
| **Sign and upload to TestFlight** | Only for a version tag `vMAJOR.MINOR.PATCH` (or a manual re-run of that tag) | Required |

Signing is **manual** (your Distribution `.p12` + App Store provisioning profile) plus an App Store Connect API key. That is more predictable on a GitHub-hosted runner than Xcode automatic signing (`-allowProvisioningUpdates`). `fastlane match` is not used.

## Release flow

Ship a build by pushing a **version tag**. From Windows (Git Bash, PowerShell, or GitHub Desktop):

```powershell
git checkout main
git pull origin main
git tag v1.0.0
git push origin v1.0.0
```

That push starts **iOS TestFlight**. After the unsigned simulator job passes, the signed job archives, signs, and uploads the IPA.

### Tag format

- Required: `vMAJOR.MINOR.PATCH` — examples: `v1.0.0`, `v1.2.3`, `v2.0.0`
- Rejected: `v1.2`, `1.2.3`, `v1.2.3-beta`, `release-1.0.0`, a branch name

The workflow strips the leading `v` and fails with a named error if the tag is not strict semver.

### Versioning scheme

| Field | Source | Example for `v1.2.3` |
| --- | --- | --- |
| Marketing version (`CFBundleShortVersionString`) | Tag without `v` | `1.2.3` |
| Build number (`CFBundleVersion`) | `MAJOR * 1000000 + MINOR * 1000 + PATCH` | `1002003` |

The build number is **deterministic** (the same tag always encodes the same number) and **monotonically increasing** as you bump MAJOR / MINOR / PATCH. Limits: major ≤ 2000, minor ≤ 999, patch ≤ 999.

Because one tag maps to one build number, a tag cannot upload two different binaries. To ship a new binary, push a new tag (`v1.0.1`, not a second `v1.0.0`).

Unsigned CI compiles on branches use marketing version `0.0.0` and `github.run_number` as the build number (not uploaded).

### Optional manual re-run

**Actions → iOS TestFlight → Run workflow** is a fallback that re-runs **an existing tag**. You must type the tag (`v1.2.3`) in the `tag` input. The branch picker only selects which workflow file to use; the app is checked out from the tag. This does **not** release an arbitrary branch.

Re-dispatching a tag that already landed on TestFlight will fail at upload (duplicate `CFBundleVersion`). Use it after a failed release of that same tag.

Concurrency group `release-vX.Y.Z` allows only one in-flight upload per tag (`cancel-in-progress` is off for tags).

## Secrets and variables

Add these under the GitHub repo: **Settings → Secrets and variables → Actions**.

### Required secrets

| Secret | What it is |
| --- | --- |
| `APPLE_TEAM_ID` | 10-character Team ID from [developer.apple.com/account](https://developer.apple.com/account) (Membership). |
| `IOS_DIST_CERT_P12_BASE64` | Base64 of the **Apple Distribution** `.p12` (not a Development certificate). |
| `IOS_DIST_CERT_PASSWORD` | Password you set when exporting that `.p12`. |
| `IOS_PROVISIONING_PROFILE_BASE64` | Base64 of the **App Store** `.mobileprovision` for the same bundle id and Distribution cert. |
| `ASC_KEY_ID` | App Store Connect API key id (for example `AB12CD34EF`). |
| `ASC_ISSUER_ID` | App Store Connect issuer UUID. |
| `ASC_KEY_P8_BASE64` | Base64 of the downloaded `AuthKey_XXXX.p8` file. |

### Optional repository variable

| Variable | Default | What it is |
| --- | --- | --- |
| `IOS_BUNDLE_ID` | `com.privateagent.ios` | Must match the App ID, the provisioning profile, and App Store Connect. |

The signed job fails with a named list of missing secrets if you push a version tag before these are set. Secrets are injected only into the steps that need them and are never echoed.

## 1. App ID and App Store Connect record

1. Sign in at [developer.apple.com/account](https://developer.apple.com/account) with the paid Apple Developer account.
2. **Certificates, Identifiers & Profiles → Identifiers → +**.
3. Choose **App IDs → App**.
4. Description: `PrivateAgent`.
5. Bundle ID: **Explicit** `com.privateagent.ios` (or your own, then set `IOS_BUNDLE_ID` to the same value).
6. Enable capabilities you actually use later. None are required for the first TestFlight binary.
7. Open [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → **Apps → + → New App**.
8. Platform **iOS**, name **PrivateAgent**, primary language, the same bundle id, SKU e.g. `privateagent-ios`.

## 2. App Store Connect API key

1. App Store Connect → **Users and Access → Integrations → App Store Connect API**.
2. **Team Keys → +**. Name `PrivateAgent GitHub Actions`. Access **App Manager** (or Admin).
3. Download the `.p8` once. Store it offline. Note **Key ID** and **Issuer ID**.
4. Encode the `.p8` in PowerShell (see below) → secret `ASC_KEY_P8_BASE64`.
5. Put the Key ID in `ASC_KEY_ID` and the Issuer ID in `ASC_ISSUER_ID`.

## 3. Distribution certificate and `.p12` without a Mac

Apple’s portal accepts a Certificate Signing Request. OpenSSL on Windows can make that CSR and later pack the downloaded `.cer` into a `.p12`.

In PowerShell (OpenSSL from [slproweb.com/products/Win32OpenSSL.html](https://slproweb.com/products/Win32OpenSSL.html) or `winget install ShiningLight.OpenSSL`):

```powershell
cd $env:USERPROFILE\Documents
openssl genrsa -out privateagent-distribution.key 2048
openssl req -new -key privateagent-distribution.key -out privateagent-distribution.csr -subj "/CN=PrivateAgent Distribution/C=US"
```

1. Developer portal → **Certificates → + → Apple Distribution**.
2. Upload `privateagent-distribution.csr`.
3. Download `distribution.cer` into the same folder.

Convert CER → P12:

```powershell
openssl x509 -in distribution.cer -inform DER -out privateagent-distribution.pem
openssl pkcs12 -export `
  -inkey privateagent-distribution.key `
  -in privateagent-distribution.pem `
  -out privateagent-distribution.p12 `
  -name "PrivateAgent Distribution" `
  -passout pass:CHOOSE_A_PASSWORD
```

If `openssl pkcs12 -export` errors on OpenSSL 3, add `-legacy` at the end of that command.

Keep `privateagent-distribution.key` and the `.p12` private. The password you chose is `IOS_DIST_CERT_PASSWORD`.

## 4. App Store provisioning profile

1. Developer portal → **Profiles → +**.
2. **App Store Connect → App Store** (distribution, not Development and not Ad Hoc).
3. Select the App ID from step 1.
4. Select the **Apple Distribution** certificate from step 3.
5. Name it `PrivateAgent App Store`.
6. Download `PrivateAgent_App_Store.mobileprovision`.

## 5. Base64-encode files in PowerShell

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:USERPROFILE\Documents\privateagent-distribution.p12")) | Set-Clipboard
# paste into GitHub secret IOS_DIST_CERT_P12_BASE64

[Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:USERPROFILE\Documents\PrivateAgent_App_Store.mobileprovision")) | Set-Clipboard
# paste into IOS_PROVISIONING_PROFILE_BASE64

[Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:USERPROFILE\Documents\AuthKey_XXXXXXXXXX.p8")) | Set-Clipboard
# paste into ASC_KEY_P8_BASE64
```

Do not commit these files. Do not put the raw password or `.p8` in the repo.

## 6. Watch the workflows

Compile check (no secrets):

1. Push a branch or open a pull request.
2. Open **Actions → iOS TestFlight** and confirm **Unsigned iOS simulator build**.

TestFlight upload:

1. Confirm every required secret is set.
2. `git tag v1.0.0 && git push origin v1.0.0`
3. When it succeeds, the IPA is stored as the `PrivateAgent-v1.0.0-ipa` artifact. CI runs a local IPA preflight and `xcrun altool --validate-app` before upload.
4. In App Store Connect, open the app → TestFlight. Processing can take several minutes after the job finishes (`skip_waiting_for_build_processing` is on).

The home-screen name is **Str8ZeRO** (`CFBundleDisplayName` / `CFBundleName`). The Xcode target and scheme stay `PrivateAgentApp`, and the bundle id stays `com.jaytrujillo.privateagent` (repository variable `IOS_BUNDLE_ID`).

The checked-in App Icon is the Str8ZeRO wordmark on black (`Design/Str8ZeRO_AppIcon_1024.png`, opaque RGB, no alpha). All catalog sizes (1024 / 180 / 167 / 152 / 120) are generated from that master with `python3 Scripts/generate-app-icon.py --from-png Design/Str8ZeRO_AppIcon_1024.png` and live under `Apps/PrivateAgentiOS/Assets.xcassets/AppIcon.appiconset/`.

The Sierra MacBook is not used for this path. Do not install Xcode 6-era tools or iPhone Mirroring on it.

## Signing choice (why manual)

| Approach | Used here? | Why |
| --- | --- | --- |
| Manual: Distribution `.p12` + App Store profile | Yes | Deterministic. The runner never logs into Xcode with an Apple ID. The profile you uploaded is the profile that signs the IPA. |
| Automatic: `-allowProvisioningUpdates` + ASC API key | No | Still needs a cert in the keychain. On a disposable runner it can create or rewrite profiles and fail in ways that are hard to replay from Windows. |

`fastlane match` is not used. The App Store Connect `.p8` is decoded to a temp file and passed to fastlane as `key_filepath` (not as env base64).

Manual signing is applied to the **PrivateAgentApp** target only (XcodeGen Release settings + a CI xcconfig). `xcodebuild archive` does **not** pass `PROVISIONING_PROFILE_SPECIFIER` on the command line — that override would also hit SwiftPM package products (`PrivateAgent_FlashMoEVendor`, `PrivateAgent_TurboQuantMetal`), which cannot use an App Store profile. `ExportOptions.plist` maps `IOS_BUNDLE_ID` (for example `com.jaytrujillo.privateagent`) to the profile name from the `.mobileprovision` (`PrivateAgent AppStore`) with `signingStyle: manual`, `method: app-store-connect`, and `teamID`. There are no app-extension targets; the one profile covers the main bundle id only.

## If the simulator job fails

Open the run → **Unsigned iOS simulator build** → download `ios-simulator-failure-logs` if present. The first `error:` from `xcodebuild` is the next fix. That job is the cloud compile signal for people without a modern Mac.
