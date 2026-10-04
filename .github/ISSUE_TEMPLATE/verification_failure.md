---
name: Verification failure
description: Track Swift CI or local build failures found during Agent Mode development
title: "Verification: <short failure summary>"
labels: [verification, ci]
---

## Verification Target

- Commit SHA:
- Workflow run URL:
- Local environment, if any:

## Command or Workflow

```bash
swift package resolve
swift build -v
swift test -v
```

## Failure Summary

Paste the first actionable compiler/test error here.

```text

```

## Expected Fix Area

- [ ] Package manifest
- [ ] AgentCore
- [ ] PrivateAgentUI
- [ ] SwiftData model/schema
- [ ] Tests
- [ ] CI/toolchain
- [ ] Other

## Notes

Keep this issue focused on the first failing error. Once fixed, rerun Swift CI and open a new issue for the next independent failure if needed.
