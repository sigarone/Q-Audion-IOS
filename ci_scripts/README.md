# `ci_scripts/` — DEAD CODE (Xcode Cloud convention)

> **These scripts are NOT executed by the active iOS build pipeline.**

The active pipeline is **GitHub Actions** — `.github/workflows/ios-testflight.yml`. It runs on `macos-latest` with Xcode 26.x and uploads to TestFlight Internal group `Q-Audion testers` via `xcrun altool`.

The three scripts in this directory (`ci_post_clone.sh`, `ci_pre_xcodebuild.sh`, `ci_post_xcodebuild.sh`) follow the Xcode Cloud naming convention and were created in 2026 for an Xcode Cloud migration that was **never adopted** (see [`../XCODE_CLOUD_MIGRATION.md`](../XCODE_CLOUD_MIGRATION.md) for the historical proposal).

## What this means for agents working on CI

- **Do NOT** edit these scripts expecting CI to pick the changes up — only `.github/workflows/*.yml` is wired into the runner.
- The build steps these scripts contain (xcodegen install, version bump, onnxruntime patch) are **already replicated inline** in `ios-testflight.yml`. Edit the workflow, not these scripts.
- If Xcode Cloud is ever revisited, these scripts are the starting point. Until then, treat them as paper trail.

For the canonical CI / build description see the top of [`../CLAUDE.md`](../CLAUDE.md) § "CI / BUILD PLATFORM".
