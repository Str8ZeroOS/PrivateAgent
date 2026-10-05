# TestFlight setup from Windows (no Mac)

PrivateAgent is built in GitHub Actions on a hosted macOS runner with a current Xcode that supports Swift 6. A Mac OS X 10.12.6 machine cannot run that toolchain or iPhone Mirroring. You do **not** need a modern Mac to ship a TestFlight build.

The workflow is `.github/workflows/ios-testflight.yml`.

- **Unsigned iOS simulator build** runs on every push and pull request. No secrets. This is the compile check.
- **Sign and upload to TestFlight** runs only on **Actions → iOS TestFlight → Run workflow**. It uses **manual signing** (your Distribution `.p12` + App Store provisioning profile) plus an App Store Connect API key. That is more predictable on a GitHub-hosted runner than Xcode automatic signing (`-allowProvisioningUpdates`), which still needs a certificate in the keychain and can change profiles during the job.

Build number is `github.run_number`. Version string is `0.1.0` (`MARKETING_VERSION` in the workflow and `project.yml`).

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

The job fails with a named list of missing secrets if you dispatch TestFlight before these are set.

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

## 6. Run the workflows

Compile check (no secrets):

1. Push to this repository, or open **Actions → iOS TestFlight** and confirm the **Unsigned iOS simulator build** job on the latest run.

TestFlight upload:

1. Confirm every required secret is set.
2. **Actions → iOS TestFlight → Run workflow** on `main` or this branch.
3. When it succeeds, the IPA is also stored as the `PrivateAgent-testflight-ipa` artifact.
4. In App Store Connect, open the app → TestFlight. Processing can take several minutes after the job finishes (`skip_waiting_for_build_processing` is on).

The Sierra MacBook is not used for this path. Do not install Xcode 6-era tools or iPhone Mirroring on it.

## Signing choice (why manual)

| Approach | Used here? | Why |
| --- | --- | --- |
| Manual: Distribution `.p12` + App Store profile | Yes | Deterministic. The runner never logs into Xcode with an Apple ID. The profile you uploaded is the profile that signs the IPA. |
| Automatic: `-allowProvisioningUpdates` + ASC API key | No | Still needs a cert in the keychain. On a disposable runner it can create or rewrite profiles and fail in ways that are hard to replay from Windows. |

`fastlane match` is not used.

## If the simulator job fails

Open the run → **Unsigned iOS simulator build** → download `ios-simulator-failure-logs` if present. The first `error:` from `xcodebuild` is the next fix. That job is the cloud compile signal for people without a modern Mac.
