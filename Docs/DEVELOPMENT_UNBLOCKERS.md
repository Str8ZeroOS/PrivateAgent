# Development Unblockers

This repo includes two guardrails so development does not stop when a local machine cannot clone or build the project.

## 1. GitHub Actions is the source of build truth

`/.github/workflows/swift-ci.yml` runs on every push, pull request, and manual dispatch. It checks out the repo on macOS, selects Xcode 16 when available, then runs:

```bash
swift package resolve
swift build -v
swift test -v
```

Use this when a local workstation has TLS, Git, certificate, or platform limitations. The CI result is the authoritative compile/test signal.

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

Use GitHub Actions. Push changes through the GitHub API/connector or from another machine, then check the Swift CI workflow. This keeps development moving even when one host cannot establish GitHub TLS sessions.
