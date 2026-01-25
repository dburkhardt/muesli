# Code Signing Strategy for Muesli

This document outlines how code signing works in Muesli, best practices for maintaining TCC (Transparency, Consent, and Control) permission stability, and recommendations for avoiding unnecessary permission resets during development.

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [How TCC Permissions Work](#how-tcc-permissions-work)
3. [Code Signing Fundamentals](#code-signing-fundamentals)
4. [Current Project Configuration](#current-project-configuration)
5. [The Problem: Unnecessary TCC Resets](#the-problem-unnecessary-tcc-resets)
6. [Recommendations](#recommendations)
7. [Implementation Plan](#implementation-plan)
8. [Local Development Workflow](#local-development-workflow)
9. [CI/CD Signing](#cicd-signing)
10. [Verification Commands](#verification-commands)
11. [Troubleshooting](#troubleshooting)
12. [Validation Testing](#validation-testing)

---

## Executive Summary

**Current State**: Muesli has proper stable code signing configured (`DEVELOPMENT_TEAM` in `project.pbxproj`), which should allow TCC permissions to persist across builds. However, TCC permissions are reset on every build by **two independent mechanisms**:
1. The build script (`scripts/build-and-launch.sh`) at lines 504-545
2. An Xcode build phase ("Reset TCC Permissions") in `project.pbxproj` at lines 457-474

Both reset TCC permissions AND UserDefaults, forcing users to re-grant permissions and redo onboarding unnecessarily.

**Key Insight**: With stable code signing, you do NOT need to reset TCC permissions on every build. The permission resets were likely added during early development when ad-hoc signing was causing permission instability.

**Recommendation**: Remove the TCC reset from both locations by default. TCC resets should only be done when explicitly requested (e.g., for testing onboarding flow).

---

## How TCC Permissions Work

### What is TCC?

TCC (Transparency, Consent, and Control) is macOS's privacy protection framework. It manages access to sensitive resources like:
- Screen Recording (`ScreenCapture`)
- Microphone (`Microphone`)
- Camera (`Camera`)
- Accessibility (`Accessibility`)
- Contacts, Calendar, Photos, etc.

### How TCC Identifies Apps

TCC tracks permissions based on **two factors**:
1. **Bundle ID** (`com.muesli.app`)
2. **Code Signing Identity** (the designated requirement)

When you grant permission to an app, TCC stores an entry in its database that associates:
- The bundle ID
- The code signing designated requirement
- The permission state (granted/denied)

### TCC Database Locations

```
# User-level permissions (where most permissions are stored)
$HOME/Library/Application Support/com.apple.TCC/TCC.db

# System-level permissions (SIP-protected)
/Library/Application Support/com.apple.TCC/TCC.db
```

### Why Permissions Reset

TCC will invalidate previously granted permissions when:

1. **Code signature changes significantly** - If the signing identity changes between builds, TCC no longer recognizes the app as "the same app" that was granted permission.

2. **Bundle ID changes** - A different bundle ID is treated as a completely different app.

3. **Designated requirement changes** - The designated requirement is a cryptographic description of who signed the app. Changes invalidate permissions.

### The Designated Requirement

Every signed macOS app has a "designated requirement" - a code signing rule that uniquely identifies valid signatures for the app. You can view it with:

```bash
codesign -d -r- /path/to/App.app
```

Example output for a properly signed app:
```
designated => identifier "com.muesli.app" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = J3Q35LXP2V
```

This requirement says: "This app must be signed by a certificate from team J3Q35LXP2V."

With stable team-based signing, this requirement remains constant across builds, so TCC continues to recognize the app.

---

## Code Signing Fundamentals

### Signing Identity Types

| Type | Use Case | TCC Stability |
|------|----------|---------------|
| **Ad-hoc / Sign to Run Locally** | Quick local testing | ❌ Unstable - changes every build |
| **Apple Development** | Team development | ✅ Stable - same team identity |
| **Developer ID Application** | Distribution outside App Store | ✅ Stable - same certificate |

### Ad-hoc Signing Problems

"Sign to Run Locally" (ad-hoc signing) creates a self-signed, machine-specific signature that:
- Has no stable team identifier
- Changes the designated requirement on each build
- Causes TCC to invalidate permissions after every rebuild
- Makes `CGPreflightScreenCaptureAccess()` unreliable

### Team-Based Signing Benefits

Using `DEVELOPMENT_TEAM` in your Xcode project:
- Provides a stable team identifier in the designated requirement
- Allows TCC permissions to persist across rebuilds
- Makes `CGPreflightScreenCaptureAccess()` reliable
- Supports Keychain access persistence
- Works with incremental builds

### Automatic vs Manual Signing

**Automatic Signing** (recommended for development):
```
CODE_SIGN_STYLE = Automatic
DEVELOPMENT_TEAM = <your-team-id>
```

Xcode automatically selects the appropriate certificate and provisioning profile.

**Manual Signing** (for CI or special cases):
```
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = "Developer ID Application: Your Name (TEAM_ID)"
PROVISIONING_PROFILE_SPECIFIER = "ProfileName"
```

---

## Current Project Configuration

### Xcode Project Settings

From `Muesli.xcodeproj/project.pbxproj`:

```
// Both Debug and Release configurations
CODE_SIGN_ENTITLEMENTS = Muesli/Muesli.entitlements
CODE_SIGN_STYLE = Automatic
DEVELOPMENT_TEAM = J3Q35LXP2V
ENABLE_HARDENED_RUNTIME = YES
PRODUCT_BUNDLE_IDENTIFIER = com.muesli.app
```

**Analysis**: This is correctly configured for stable code signing. The `DEVELOPMENT_TEAM` setting ensures that all builds are signed with the same team identity, allowing TCC permissions to persist.

### Entitlements

From `Muesli/Muesli.entitlements`:

```xml
<key>com.apple.security.app-sandbox</key>
<false/>
<key>com.apple.security.device.audio-input</key>
<true/>
```

**Notes**:
- App sandbox is disabled (required for ScreenCaptureKit system audio capture)
- Microphone entitlement is enabled

### Build Script Behavior

From `scripts/build-and-launch.sh` (lines 504-545):

```bash
# Current behavior - runs on EVERY build
tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null
tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null
```

The build script currently:
1. Registers the app with Launch Services
2. **Resets Screen Recording permission** (`tccutil reset ScreenCapture $BUNDLE_ID`)
3. **Resets Microphone permission** (`tccutil reset Microphone $BUNDLE_ID`)

This forces users to re-grant permissions on every build, even though the code signature is stable.

### Xcode Build Phase (CRITICAL)

**In addition to the build script**, there is a build phase in `Muesli.xcodeproj/project.pbxproj` (lines 457-474) named "Reset TCC Permissions" that runs during **every Xcode build**:

```bash
# From project.pbxproj - "Reset TCC Permissions" build phase
# This runs even when building from Xcode directly (not using build script)
tccutil reset ScreenCapture com.muesli.app 2>/dev/null || true
tccutil reset Microphone com.muesli.app 2>/dev/null || true
# ALSO resets ALL UserDefaults (onboarding state, model paths, etc.)
defaults delete com.muesli.app 2>/dev/null || true
```

**Impact**: Even if the build script is fixed, developers building directly from Xcode (⌘R) will still experience permission and state resets. **Both locations must be addressed** for the plan to be complete.

**Note**: The build phase is more aggressive than the script - it also resets UserDefaults, wiping onboarding completion state, model preferences, and other saved settings.

---

## The Problem: Unnecessary TCC Resets

### Historical Context

The TCC reset step was likely added when:
1. The project used ad-hoc signing (no `DEVELOPMENT_TEAM`)
2. Every build had a different code signature
3. TCC permissions would break unpredictably
4. Resetting ensured a clean slate for testing

### Current Reality

With `DEVELOPMENT_TEAM = J3Q35LXP2V` configured:
1. All builds have the same team-based signing identity
2. The designated requirement stays constant
3. TCC recognizes all builds as "the same app"
4. **Permissions should persist across rebuilds**

### Evidence

From `docs/debug-logs/2026-01-15_screen-recording-permission-detection.md`:

> **Update (2026-01-21):** This issue is now mitigated by configuring stable code signing with `DEVELOPMENT_TEAM` in `project.pbxproj`. With stable signing:
> - `CGPreflightScreenCaptureAccess()` becomes reliable
> - **TCC permissions persist across rebuilds**
> - Permission caching (5-minute TTL) reduces SCShareableContent calls

The documentation confirms that stable signing enables TCC persistence, yet the build script still resets permissions.

### Impact

Current behavior forces developers to:
1. Wait through TCC permission prompts after every build
2. Re-click through System Settings to grant permissions
3. Potentially redo the onboarding flow
4. Lose productivity on routine development tasks

---

## Recommendations

### 1. Remove TCC Reset from Default Build

**Change**: Make TCC reset opt-in rather than default.

```bash
# Current (problematic):
# TCC reset runs on every build by default

# Proposed:
# TCC reset only runs when explicitly requested
./scripts/build-and-launch.sh              # No TCC reset (normal development)
./scripts/build-and-launch.sh --reset-tcc  # With TCC reset (onboarding testing)
```

### 2. Add a Separate Onboarding Test Script

Create a dedicated script for testing onboarding:

```bash
# scripts/test-onboarding.sh
#!/bin/bash
# Reset all state for fresh onboarding experience
tccutil reset ScreenCapture com.muesli.app
tccutil reset Microphone com.muesli.app
defaults delete com.muesli.app  # Clear all UserDefaults
./scripts/build-and-launch.sh --no-log
```

### 3. Enable Incremental Builds for Development

With stable signing, incremental builds should work correctly:

```bash
# For rapid iteration during development
./scripts/build-and-launch.sh --preserve-caches
```

Or add a new flag:

```bash
./scripts/build-and-launch.sh --incremental  # Uses cached build, no TCC reset
```

### 4. Verify Signing Before Relying on TCC Persistence

Add a verification step to confirm stable signing:

```bash
# Verify team-based signing is working
APP_PATH="./DerivedData/Build/Products/Debug/Muesli.app"
codesign -d -r- "$APP_PATH" 2>&1 | grep "subject.OU = J3Q35LXP2V"
if [ $? -eq 0 ]; then
    echo "✓ Stable team signing verified"
else
    echo "⚠ Warning: App may not have stable signing"
fi
```

### 5. Document When TCC Reset IS Needed

TCC reset should be used when:
- Testing the onboarding flow from scratch
- Debugging permission-related issues
- Switching between bundle IDs (worktree branches)
- After changing the `DEVELOPMENT_TEAM`
- After certificate renewal/expiration

### 6. Remove or Conditionally Disable Xcode Build Phase

The "Reset TCC Permissions" build phase must also be addressed. Options:

**Option A (Recommended)**: Remove the build phase entirely
- Delete the build phase from `project.pbxproj`
- Use `--reset-tcc` flag or `test-onboarding.sh` when needed
- Cleanest solution; no accidental resets

**Option B**: Make the build phase conditional with a user-defined build setting
- Add `RESET_TCC_PERMISSIONS = NO` to project build settings
- Update build phase script to check the setting:
  ```bash
  if [ "$RESET_TCC_PERMISSIONS" = "YES" ]; then
      tccutil reset ScreenCapture com.muesli.app 2>/dev/null || true
      tccutil reset Microphone com.muesli.app 2>/dev/null || true
      defaults delete com.muesli.app 2>/dev/null || true
      echo "TCC permissions and app state reset"
  else
      echo "Skipping TCC reset (RESET_TCC_PERMISSIONS != YES)"
  fi
  ```
- Set to `YES` only in a dedicated "Onboarding Test" scheme

**Option C**: Keep build phase but disable by default in scheme settings
- Rename to "Reset TCC Permissions (Disabled by Default)"
- Uncheck "Show environment variables in build log" and leave unchecked by default
- Developers enable manually when needed

**Recommendation**: Option A is cleanest. The dedicated `test-onboarding.sh` script provides the same functionality when actually needed.

### 7. Clarify UserDefaults Reset Strategy

The build phase currently resets both TCC permissions AND UserDefaults. For the proposed `test-onboarding.sh` script:

- **TCC reset**: Required for testing permission grant flow
- **UserDefaults reset**: Required for testing complete onboarding experience (completion state, model selection, etc.)

**Recommendation**: Keep both resets in `test-onboarding.sh` but remove from normal build workflow. This ensures onboarding testing gets a truly clean slate while daily development preserves user state.

---

## Implementation Plan

This section provides the specific implementation steps to execute the recommendations.

### Phase 1: Modify Build Script (scripts/build-and-launch.sh)

**Changes required**:

1. Add `RESET_TCC=false` variable (after line 52):
   ```bash
   RESET_TCC=false
   ```

2. Add `--reset-tcc` flag parsing (in argument parsing section, around line 105):
   ```bash
   --reset-tcc)
       RESET_TCC=true
       shift
       ;;
   ```

3. Update help text to document the flag:
   ```bash
   echo "  --reset-tcc        Reset TCC permissions (for onboarding testing)"
   ```

4. Make TCC reset conditional (wrap lines 504-545):
   ```bash
   if [ "$RESET_TCC" = true ]; then
       print_step "Resetting system permissions for ${BUNDLE_ID}..."
       # ... existing TCC reset code ...
       print_info "You will need to re-grant permissions on first launch"
   else
       print_info "Skipping TCC reset (permissions will persist from previous builds)"
   fi
   ```

### Phase 2: Remove Xcode Build Phase

**Changes required** to `Muesli.xcodeproj/project.pbxproj`:

1. Remove the entire build phase definition (lines 457-475):
   - Delete the `A1000031241D1A1D00000003 /* Reset TCC Permissions */` section

2. Remove the build phase reference from the Muesli target (line 505):
   - Delete `A1000031241D1A1D00000003 /* Reset TCC Permissions */,` from the `buildPhases` array

**Alternative** (if Option B is chosen): Modify the shell script in the build phase to check for a build setting.

### Phase 3: Create Onboarding Test Script

Create `scripts/test-onboarding.sh`:

```bash
#!/bin/bash
# scripts/test-onboarding.sh
# Reset all state for testing the onboarding flow from scratch
#
# Usage: ./scripts/test-onboarding.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Detect bundle ID from worktree config or use default
if [ -f ".worktree-config.json" ] && command -v jq &> /dev/null; then
    BUNDLE_ID=$(jq -r ".bundleId // \"com.muesli.app\"" .worktree-config.json)
else
    BUNDLE_ID="com.muesli.app"
fi

echo "🧹 Resetting all state for onboarding testing..."
echo "   Bundle ID: $BUNDLE_ID"
echo ""

# Reset TCC permissions
echo "Resetting Screen Recording permission..."
tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || echo "   (no entries to reset)"

echo "Resetting Microphone permission..."
tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null || echo "   (no entries to reset)"

# Reset UserDefaults (onboarding state, model paths, etc.)
echo "Resetting UserDefaults..."
defaults delete "$BUNDLE_ID" 2>/dev/null || echo "   (no entries to reset)"

echo ""
echo "✅ State reset complete. Building and launching..."
echo ""

# Build and launch
./scripts/build-and-launch.sh --no-log
```

Make executable: `chmod +x scripts/test-onboarding.sh`

### Phase 4: Update Documentation

**AGENTS.md** (around line 122, Commands section):

Update the reset permissions command:
```markdown
- Reset permissions (onboarding testing only): `./scripts/test-onboarding.sh` or `./scripts/build-and-launch.sh --reset-tcc`
```

Add note about TCC persistence:
```markdown
**TCC Permission Persistence**: With stable code signing (`DEVELOPMENT_TEAM`), TCC permissions persist across builds. You only need to grant permissions once after a fresh clone. Use `--reset-tcc` or `test-onboarding.sh` only when testing the onboarding flow.
```

### Acceptance Criteria

- [ ] Build script runs without TCC reset by default
- [ ] `--reset-tcc` flag successfully resets permissions when provided
- [ ] Xcode build phase removed or disabled by default
- [ ] Building from Xcode (⌘R) does not reset permissions
- [ ] `test-onboarding.sh` provides complete state reset for onboarding testing
- [ ] TCC permissions persist across 5+ consecutive builds (validated)
- [ ] Designated requirement is stable across builds (verified with `codesign -d -r-`)
- [ ] AGENTS.md updated with new workflow guidance
- [ ] Worktree branches correctly detect their bundle ID for `--reset-tcc`

### Migration Communication

When this change lands, communicate to developers:

```
🚀 Build Script Improvement: TCC Permissions Now Persist!

Previously, every build reset Screen Recording and Microphone permissions,
requiring you to re-grant them and potentially redo onboarding.

With stable code signing, this is no longer necessary. Permissions now persist.

**What's changed:**
- Default builds: No TCC reset (permissions persist)
- Xcode builds (⌘R): No TCC reset (build phase removed)

**To test onboarding from scratch:**
- Use: ./scripts/test-onboarding.sh
- Or: ./scripts/build-and-launch.sh --reset-tcc

**First build after this change:**
You may need to grant permissions once. Subsequent builds will remember them.
```

---

## Local Development Workflow

### Recommended Daily Workflow

```bash
# Normal development (permissions persist)
./scripts/build-and-launch.sh

# First time setup or after git clone
./scripts/build-and-launch.sh  # Grant permissions once when prompted
# Subsequent builds won't need permission re-granting
```

### Testing Onboarding

```bash
# Only when you need to test onboarding
./scripts/build-and-launch.sh --reset-tcc  # (proposed flag)
# Or use dedicated script
./scripts/test-onboarding.sh  # (proposed script)
```

### Using Xcode Directly

You can also build and run from Xcode:
1. Open `Muesli.xcodeproj`
2. Select the Muesli scheme
3. Press ⌘R to build and run

Benefits:
- Xcode manages DerivedData
- Faster incremental builds
- Integrated debugging

**Important**: After implementing the changes in this plan, permissions will persist when building from Xcode. Currently, the "Reset TCC Permissions" build phase resets permissions on every Xcode build - this build phase should be removed (see Recommendation #6 and Implementation Phase 2).

### Worktree Branches

When using worktree isolation (different bundle IDs per branch):
- TCC permissions are **per-bundle-ID**, so each worktree has separate permissions
- First build in a new worktree requires granting permissions once
- The `--reset-tcc` flag and `test-onboarding.sh` script automatically detect the current branch's bundle ID from `.worktree-config.json`
- To manually reset permissions for a specific worktree bundle ID:
  ```bash
  tccutil reset ScreenCapture com.muesli.app.xxx
  tccutil reset Microphone com.muesli.app.xxx
  defaults delete com.muesli.app.xxx
  ```

### Verifying Your Signing Identity

```bash
# Check your available signing identities
security find-identity -v -p codesigning

# Verify the built app's signature
codesign -dvv ./DerivedData/Build/Products/Debug/Muesli.app

# View the designated requirement (should include your team ID)
codesign -d -r- ./DerivedData/Build/Products/Debug/Muesli.app
```

---

## CI/CD Signing

### Current CI Configuration

From `.github/workflows/ci.yml`:

```yaml
# CI uses the same Developer ID certificate as releases
# This prevents "TCC thrash" and ensures consistent identity
```

Required secrets:
- `DEVELOPER_ID_CERT_P12` - Base64-encoded .p12 certificate
- `DEVELOPER_ID_CERT_PASSWORD` - Certificate password

### Why Same Certificate Matters

Using the same Developer ID certificate for CI and releases ensures:
1. **Consistent code signature** - All builds (local, CI, release) share the same signing identity
2. **No TCC thrash** - Users don't lose permissions when updating from CI builds
3. **Predictable behavior** - Testing CI builds accurately reflects release behavior

### Release Workflow

From `.github/workflows/release.yml`:

1. Build with Developer ID signing
2. Sign the DMG
3. Notarize with Apple (`xcrun notarytool`)
4. Staple notarization ticket
5. Generate artifact attestation

### Local vs CI Signing Comparison

| Aspect | Local Development | CI/Release |
|--------|-------------------|------------|
| Certificate | Apple Development (automatic) | Developer ID Application |
| Team ID | J3Q35LXP2V | J3Q35LXP2V |
| Notarization | No | Yes |
| TCC Stability | ✅ Stable | ✅ Stable |
| Hardened Runtime | Yes | Yes |

Both share the same team ID, so TCC permissions granted to one should work for the other (though notarization provides additional trust).

### CI Build Behavior

CI builds do NOT and CANNOT reset TCC permissions:
- GitHub Actions runners have no TCC database access
- No `tccutil` commands in CI workflows
- CI relies on headless mode where TCC doesn't apply

This confirms that TCC reset is purely a **local development convenience**, not a build requirement. The CI workflow proves the app builds and runs correctly without TCC resets.

---

## Verification Commands

### Check App Signing Status

```bash
# Basic signature verification
codesign --verify --deep --strict ./DerivedData/Build/Products/Debug/Muesli.app

# Detailed signature information
codesign -dvv ./DerivedData/Build/Products/Debug/Muesli.app

# View designated requirement
codesign -d -r- ./DerivedData/Build/Products/Debug/Muesli.app 2>&1

# Check entitlements
codesign -d --entitlements - ./DerivedData/Build/Products/Debug/Muesli.app
```

### Check TCC Database Status

```bash
# Note: Reading TCC database requires Full Disk Access
# This is for debugging only

# Check if app has screen recording permission
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT * FROM access WHERE client='com.muesli.app' AND service='kTCCServiceScreenCapture';"

# Check microphone permission
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT * FROM access WHERE client='com.muesli.app' AND service='kTCCServiceMicrophone';"
```

### Check Signing Identities

```bash
# List all signing identities
security find-identity -v -p codesigning

# Check specific team's certificates
security find-identity -v -p codesigning | grep "J3Q35LXP2V"
```

### Available TCC Services

```bash
# List all TCC service names on your system
strings /System/Library/PrivateFrameworks/TCC.framework/Support/tccd \
  | grep kTCCService \
  | grep -v ' ' \
  | sed 's/kTCCService//' \
  | sort
```

---

## Troubleshooting

### Permissions Don't Persist After Rebuild

**Symptoms**: Every build requires re-granting permissions.

**Checks**:
1. Verify `DEVELOPMENT_TEAM` is set in `project.pbxproj`
   ```bash
   grep DEVELOPMENT_TEAM Muesli.xcodeproj/project.pbxproj
   ```

2. Verify the built app has team-based signing
   ```bash
   codesign -d -r- ./DerivedData/Build/Products/Debug/Muesli.app
   # Should show: certificate leaf[subject.OU] = J3Q35LXP2V
   ```

3. Check if build script is resetting permissions
   ```bash
   grep -n "tccutil reset" scripts/build-and-launch.sh
   ```

**Solution**: Remove TCC reset from build script, or use `--preserve-caches` flag.

### CGPreflightScreenCaptureAccess Returns False Incorrectly

**Symptoms**: App thinks screen recording permission is denied when it's actually granted.

**Checks**:
1. Verify stable signing (see above)
2. Check the permission cache TTL hasn't expired
3. Verify you're running the correct build

**Solution**: Ensure stable signing is configured. The codebase now uses async permission checks with caching as a backup (see `docs/debug-logs/2026-01-15_screen-recording-permission-detection.md`).

### Certificate Not Found

**Symptoms**: Build fails with "No signing certificate found."

**Checks**:
1. Verify certificate is in Keychain
   ```bash
   security find-identity -v -p codesigning
   ```

2. Check certificate hasn't expired
   ```bash
   security find-certificate -a -c "Apple Development" -p | openssl x509 -noout -dates
   ```

**Solution**: 
- Open Xcode → Preferences → Accounts → Download Manual Profiles
- Or regenerate certificate in Apple Developer Portal

### Worktree Branch Has Wrong Bundle ID

**Symptoms**: Feature branch has different bundle ID, causing separate TCC permissions.

**Checks**:
```bash
# Check bundle ID in project
grep PRODUCT_BUNDLE_IDENTIFIER Muesli.xcodeproj/project.pbxproj | head -1

# Check worktree config
cat .worktree-config.json
```

**Solution**: This is intentional for worktree isolation. Each bundle ID has separate permissions. Run `./scripts/configure-worktree.sh` to set up properly, or use `tccutil reset` for the branch-specific bundle ID.

---

## Validation Testing

Before implementing changes, validate that stable signing is working as expected.

### Test 1: Verify Designated Requirement Stability

Build twice and confirm the designated requirement is identical:

```bash
# Build 1
./scripts/build-and-launch.sh --build-only
codesign -d -r- ./DerivedData/Build/Products/Debug/Muesli.app 2>&1 | grep "designated" > /tmp/sig1.txt

# Build 2 (clean)
rm -rf ./DerivedData
./scripts/build-and-launch.sh --build-only
codesign -d -r- ./DerivedData/Build/Products/Debug/Muesli.app 2>&1 | grep "designated" > /tmp/sig2.txt

# Compare
diff /tmp/sig1.txt /tmp/sig2.txt && echo "✅ Designated requirement stable" || echo "❌ Requirement changed!"
```

**Expected**: No differences. Both builds should have identical designated requirements containing `subject.OU = J3Q35LXP2V`.

### Test 2: Verify TCC Persistence (Manual)

1. Comment out TCC reset in build script temporarily
2. Build and launch: `./scripts/build-and-launch.sh`
3. Grant Screen Recording and Microphone permissions when prompted
4. Quit the app
5. Rebuild and launch: `./scripts/build-and-launch.sh`
6. **Expected**: No permission prompts. App should have access immediately.

If permissions persist, stable signing is working correctly.

### Test 3: Verify Build Phase Impact

1. With build phase still in `project.pbxproj`:
   - Build from Xcode (⌘R)
   - Note: Permissions should be reset (current behavior)
2. Remove build phase per Implementation Phase 2
3. Build from Xcode (⌘R)
   - Grant permissions when prompted
4. Rebuild from Xcode (⌘R)
   - **Expected**: No permission prompts

### Test 4: Smoke Test Script

After implementation, create a smoke test:

```bash
#!/bin/bash
# scripts/test-tcc-persistence.sh
# Verify that TCC permissions persist across builds

echo "Testing TCC permission persistence..."
echo "This test requires manual verification."
echo ""

# Build 1
echo "Step 1: Building app (build 1 of 2)..."
./scripts/build-and-launch.sh --build-only 2>&1 | tail -5

# Check signature
SIG1=$(codesign -d -r- ./DerivedData/Build/Products/Debug/Muesli.app 2>&1 | grep "subject.OU")

# Build 2
echo "Step 2: Rebuilding app (build 2 of 2)..."
./scripts/build-and-launch.sh --build-only 2>&1 | tail -5

# Check signature again
SIG2=$(codesign -d -r- ./DerivedData/Build/Products/Debug/Muesli.app 2>&1 | grep "subject.OU")

echo ""
echo "Signature comparison:"
echo "  Build 1: $SIG1"
echo "  Build 2: $SIG2"
echo ""

if [ "$SIG1" = "$SIG2" ]; then
    echo "✅ Code signature stable - TCC permissions should persist"
else
    echo "❌ Code signature changed - TCC will reset permissions"
    exit 1
fi
```

---

## Future Considerations

### Certificate Renewal

Developer ID certificates are valid for 5 years. When renewal is needed:
1. Generate new certificate in Apple Developer Portal
2. Export as .p12 and update GitHub secrets
3. Update local Keychain
4. Note: Apps signed with expired certificate still run; only new signatures need new cert

### Team Member Onboarding

For new team members:
1. Add them to the Apple Developer team
2. They download their Apple Development certificate via Xcode
3. Automatic signing uses their personal cert but same team ID
4. TCC permissions granted to one team member's build work for others (same team ID)

### Migration to App Sandbox

If migrating to sandboxed distribution:
1. Enable `com.apple.security.app-sandbox` in entitlements
2. Add specific entitlement requests for screen capture, microphone
3. Test TCC behavior with sandbox enabled
4. Note: ScreenCaptureKit works differently in sandboxed apps

---

## Summary

| Scenario | TCC Reset? | Clean Build? | Notes |
|----------|------------|--------------|-------|
| Normal development (script) | ❌ No | Optional | Permissions persist |
| Normal development (Xcode) | ❌ No* | Optional | *After build phase removed |
| Testing onboarding | ✅ Yes | Yes | Use `test-onboarding.sh` or `--reset-tcc` |
| Switching branches | ❌ No | Recommended | Same bundle ID |
| Worktree branches | ⚠️ First time | Yes | Different bundle ID = separate permissions |
| After cert renewal | ❌ No | Yes | Same team ID |
| Fresh git clone | ❌ No | Yes | Grant once, persists |
| CI builds | N/A | Yes | No TCC in CI environment |

**Bottom line**: With stable code signing properly configured, you should only need to grant TCC permissions once. Neither the build script nor the Xcode build phase should reset them by default.

### Quick Reference

```
┌─────────────────────────────────────────────────────────────────┐
│ Code Signing Quick Reference                                    │
├─────────────────────────────────────────────────────────────────┤
│ ✅ Stable signing enabled: DEVELOPMENT_TEAM = J3Q35LXP2V        │
│ ✅ TCC permissions persist across builds (after implementation) │
│                                                                 │
│ Normal build:                                                   │
│   ./scripts/build-and-launch.sh                                 │
│                                                                 │
│ Test onboarding (reset all state):                              │
│   ./scripts/test-onboarding.sh                                  │
│                                                                 │
│ Verify stable signing:                                          │
│   codesign -d -r- ./DerivedData/.../Muesli.app                  │
│   # Should show: subject.OU = J3Q35LXP2V                        │
│                                                                 │
│ Manual TCC reset (if needed):                                   │
│   tccutil reset ScreenCapture com.muesli.app                    │
│   tccutil reset Microphone com.muesli.app                       │
└─────────────────────────────────────────────────────────────────┘
```

---

## Related Project Documentation

- [AGENTS.md](../AGENTS.md) - Build commands, TCC permissions section (lines 479-487)
- [spec/local_testing_workflow.md](../spec/local_testing_workflow.md) - Local development best practices
- [spec/git_workflow.md](../spec/git_workflow.md) - Branch management and worktrees
- [docs/debug-logs/2026-01-15_screen-recording-permission-detection.md](../docs/debug-logs/2026-01-15_screen-recording-permission-detection.md) - TCC detection improvements and stable signing evidence
- [scripts/configure-worktree.sh](../scripts/configure-worktree.sh) - Worktree bundle ID configuration

## References

- [Apple: macOS Code Signing In Depth (TN2206)](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)
- [Apple: Inside Code Signing Requirements (TN3127)](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
- [Apple: Signing to Run Locally](https://developer.apple.com/documentation/xcode/signing-code-for-development)
- [Apple: TCC Reset (QA1906)](https://developer.apple.com/library/archive/qa/qa1906/_index.html)
- [Apple: Build Settings Reference](https://developer.apple.com/documentation/xcode/build-settings-reference) - For conditional build phase settings

---

## Revision History

| Date | Version | Changes |
|------|---------|---------|
| 2026-01-24 | v1 | Initial version |
| 2026-01-24 | v2 | Added: Xcode build phase documentation, implementation plan with acceptance criteria, validation testing section, worktree bundle ID handling, CI behavior clarification, migration communication, quick reference card |
