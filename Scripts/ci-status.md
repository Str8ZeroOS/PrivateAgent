# CI Status Notes

After each implementation batch:

1. Open the repository on GitHub.
2. Go to **Actions**.
3. Run or inspect **Swift CI**.
4. Treat CI failures as the next development target.

This keeps build verification independent from any single local workstation. In particular, it avoids blocking on Windows schannel failures when GitHub Actions can perform a clean macOS checkout and Swift build.

Last CI trigger note: this file may be touched with a no-op documentation update when a fresh workflow run is needed after API-based changes.

Current trigger purpose: iOS simulator compile via ios-testflight.yml plus AgentCore Linux tests.
