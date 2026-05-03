#!/usr/bin/env bash
# Xcode Cloud — runs after `git clone`, before SPM dependency resolution.
# Q-Audion's xcode project is generated via XcodeGen so we must:
#   1. Install xcodegen (Apple's runners come with brew preinstalled)
#   2. Run `xcodegen generate` from the QAudionApp/ directory
#   3. Verify the .xcodeproj was produced
#
# Apple's runner has a fresh macOS image each build; nothing persists
# between runs, so we install xcodegen every time. The brew install
# step takes ~10s on the M2 runners.

set -euxo pipefail

echo "=== Xcode Cloud post_clone — Q-Audion-IOS ==="
echo "CI_WORKSPACE       = $CI_WORKSPACE"
echo "CI_PRIMARY_REPOSITORY_PATH = ${CI_PRIMARY_REPOSITORY_PATH:-<unset>}"
echo "CI_BUILD_NUMBER    = ${CI_BUILD_NUMBER:-<unset>}"
echo "CI_TAG             = ${CI_TAG:-<unset>}"
echo "CI_BRANCH          = ${CI_BRANCH:-<unset>}"
echo ""

# Install xcodegen via Homebrew. Apple's runners ship with brew at
# /opt/homebrew/bin or similar; ensure PATH covers it.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
which brew && brew --version || { echo "brew not found"; exit 1; }
brew install xcodegen
which xcodegen
xcodegen --version

# Xcode Cloud sets CI_WORKSPACE to the repo root for primary repo,
# but the variable can also be CI_PRIMARY_REPOSITORY_PATH on newer
# versions. Use whichever is set.
REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$CI_WORKSPACE}"
cd "$REPO_ROOT"
echo "=== Repo root: $(pwd) ==="
ls -la

# Generate the Xcode project from project.yml.
cd QAudionApp
xcodegen generate
echo ""
echo "=== Schemes available after xcodegen ==="
xcodebuild -project QAudionApp.xcodeproj -list 2>&1 | head -20
echo ""
echo "=== ci_post_clone.sh OK ==="
