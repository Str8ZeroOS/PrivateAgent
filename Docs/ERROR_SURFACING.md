# Automatic Error Surfacing

PrivateAgent uses CI to surface build/test problems without relying on a human to notice them manually.

## Layers

1. **Cross-platform preflight**

   `Scripts/check-cross-platform-swift.py` scans cross-platform Swift package UI code for known iOS-only APIs that fail macOS SwiftPM builds. This catches issues like:

   - `.textInputAutocapitalization(...)`
   - `.keyboardType(...)`
   - `.topBarLeading` / `.topBarTrailing` toolbar placements

2. **Swift CI build and test**

   `.github/workflows/swift-ci.yml` runs:

   ```bash
   python3 Scripts/check-cross-platform-swift.py
   swift package resolve
   swift build -v
   swift test -v
   ```

3. **Failure logs as artifacts**

   On failure, CI uploads relevant logs as `swift-ci-failure-logs`.

4. **Automatic GitHub issue**

   On push failures, CI opens or updates a `Swift CI failure` issue with:

   - commit SHA
   - workflow run URL
   - preflight log tail
   - build log tail
   - test log tail

## Why this exists

The app is primarily iOS, but the package is also built by SwiftPM on macOS. Some UI APIs compile for iOS but fail in the package-level macOS build. The preflight scanner and failure issue reporter make those errors visible immediately, without waiting for manual review.

## Adding new checks

When CI fails because of a repeated class of mistake, add a focused pattern to `Scripts/check-cross-platform-swift.py`. Keep checks narrow and actionable so they catch real hazards without blocking valid platform-conditional code.
