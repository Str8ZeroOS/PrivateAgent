# Development Unblockers

This repo includes guardrails so development does not stop when a local machine cannot clone or build the project.

## 1. GitHub Actions is the source of build truth

`/.github/workflows/swift-ci.yml` runs on push, pull request, and manual dispatch. It checks out the repo on macOS, selects a stable Xcode release, then runs:

```bash
swift package resolve
swift build -v
swift test -v
```

Use this when a local workstation has TLS, Git, certificate, or platform limitations. The CI result is the authoritative compile/test signal.

For a full iOS app compile without secrets, use **Actions → iOS TestFlight → Unsigned iOS simulator build**. To ship to a phone from Windows, set the secrets in `Docs/TESTFLIGHT_SETUP.md` and run the TestFlight job. A Mac OS X 10.12.6 machine cannot run Swift 6 / modern Xcode; GitHub-hosted macOS runners do that instead.

### If API-created commits do not trigger Actions

Some GitHub App/API commit paths may not immediately attach Actions check-runs, especially on forks or repositories where Actions still need to be enabled. When no check appears on a commit:

1. Open the repository on GitHub.
2. Go to **Actions**.
3. Select **Swift CI**.
4. Click **Run workflow** on `main`.
5. Treat the first compiler/test error as the next implementation target.

A verification issue template is available at `.github/ISSUE_TEMPLATE/verification_failure.md` for recording the first actionable failure.

## 2. Windows archive bootstrap fallback

Some managed Windows environments fail GitHub operations before TLS completes with errors like:

```text
schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS
```

When that happens, try the archive bootstrapper instead of `git clone`:

```powershell
pwsh ./Scripts/bootstrap-windows.ps1 -Destination ./PrivateAgent-main
cd ./PrivateAgent-main
swift build
swift test
```

The script downloads the GitHub source archive through .NET `HttpClient`, expands it, and places it in a local source folder. It is intended for read/build/test workflows. Use normal Git for branch work whenever Git is functional.

## If both local fetch paths fail

Use GitHub Actions. Push changes through the GitHub API/connector or from another machine, then manually run **Swift CI** from the Actions tab if no check-run appears. This keeps development moving even when one host cannot establish GitHub TLS sessions.
