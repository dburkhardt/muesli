#!/bin/bash
# scripts/test-onboarding.sh
# Reset all state for testing the onboarding flow from scratch
#
# This script resets:
# - TCC permissions (Screen Recording, Microphone) - for testing permission grant flow
# - UserDefaults (onboarding state, model paths, etc.) - for testing complete onboarding
#
# Usage: ./scripts/test-onboarding.sh

# ============================================================================
# Help
# ============================================================================

if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat <<EOF
Usage: $0

Reset all state (TCC permissions + UserDefaults) for onboarding testing.
This gives you a truly fresh first-run experience.

What gets reset:
 - Screen Recording permission (tccutil reset ScreenCapture)
 - Microphone permission (tccutil reset Microphone)
 - All UserDefaults (defaults delete <bundle-id>)
  - Onboarding completion state
  - Model selection
  - Output directory preference
  - Window positions

The script automatically detects your bundle ID from .worktree-config.json
for worktree branches, or uses com.muesli.app for main branch.

After resetting, the script builds and launches the app.

See also:
  ./scripts/build-and-launch.sh --reset-tcc  (reset TCC only, preserve UserDefaults)
EOF
    exit 0
fi

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# ============================================================================
# Bundle ID Detection (matches build-and-launch.sh logic)
# ============================================================================
# Only use worktree bundle ID if needsWorktree is explicitly true
# This prevents accidental reset of wrong app when worktree config exists but isn't active

if [ -f ".worktree-config.json" ] && command -v jq &> /dev/null; then
    NEEDS_WORKTREE=$(jq -r ".needsWorktree // false" .worktree-config.json)
    if [ "$NEEDS_WORKTREE" = "true" ]; then
        BUNDLE_ID=$(jq -r ".bundleId // \"com.muesli.app\"" .worktree-config.json)
        echo "Worktree config detected: $BUNDLE_ID"
    else
        BUNDLE_ID="com.muesli.app"
        echo "Standard configuration (main branch)"
    fi
elif [ -f ".worktree-config.json" ]; then
    echo "Warning: jq not installed - using default bundle ID"
    echo "Install jq with: brew install jq"
    BUNDLE_ID="com.muesli.app"
else
    BUNDLE_ID="com.muesli.app"
    echo "Standard configuration (main branch)"
fi

echo ""
echo "Resetting all state for onboarding testing..."
echo "   Bundle ID: $BUNDLE_ID"
echo ""

# ============================================================================
# Reset TCC Permissions
# ============================================================================
# These resets force the app to re-request permissions on next launch

echo "Resetting Screen Recording permission..."
tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || echo "   (no entries to reset)"

echo "Resetting Microphone permission..."
tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null || echo "   (no entries to reset)"

echo "Resetting System Audio Capture permission..."
tccutil reset ListenEvent "$BUNDLE_ID" 2>/dev/null || echo "   (no entries to reset)"

# ============================================================================
# Reset UserDefaults
# ============================================================================
# INTENTIONAL: This clears ALL app preferences including:
# - hasCompletedOnboarding flag
# - Selected model path
# - Output directory preference
# - Window positions
# This ensures a complete fresh onboarding experience

echo "Resetting UserDefaults (onboarding state, preferences)..."
defaults delete "$BUNDLE_ID" 2>/dev/null || echo "   (no entries to reset)"

echo ""
echo "State reset complete. Building and launching..."
echo ""

# ============================================================================
# Build and Launch
# ============================================================================

if ! ./scripts/build-and-launch.sh --no-log; then
    echo ""
    echo "Build failed. Check output above for errors."
    exit 1
fi
