# GitHub Release Issues

This document tracks issues that appear in official GitHub releases but not in local builds. These may be related to build configuration, signing, or other CI-specific behaviors.

## Issue 1: Onboarding Background Color Incorrect

**Status**: 🔄 LIKELY RESOLVED (needs verification after SDK update)

**Symptom**: Onboarding panes show a gray background instead of white.

**Environment**:
- **Affected**: Official GitHub releases (DMG downloads)
- **Not Affected**: Local builds (via `./scripts/build-and-launch.sh`)

**Likely Root Cause**: Same as Issue 4 - SDK version mismatch. The `OnboardingBackground` color asset may render differently when compiled with macOS 15 SDK vs macOS 26 SDK.

**Fix Applied**: Updated CI to use `macos-26` runner with macOS 26 SDK (see Issue 4).

**Verification Needed**: Rebuild with new CI configuration and verify background color is correct.

**Related Files**:
- `Muesli/Assets.xcassets/OnboardingBackground.colorset/Contents.json`
- `Muesli/Views/OnboardingView.swift`

---

## Issue 2: Permission Screen "Check Again" Not Styled as Button

**Symptom**: On the system screen and audio recording permissions page, the "Check Again" action appears as plain blue text instead of a properly styled button.

**Environment**:
- **Affected**: Official GitHub releases (DMG downloads)
- **Not Affected**: [To be verified in local builds]

**Expected Behavior**: "Check Again" should display as a button (likely with background, padding, rounded corners, etc.)

**Actual Behavior**: Displays as blue hyperlink-style text

**Possible Causes**:
- ButtonStyle not being applied correctly in release builds
- Missing button modifier or styling
- SwiftUI rendering difference between Debug/Release
- Asset or styling configuration not properly compiled
- Font or appearance settings affected by release configuration

**Investigation Needed**:
- [ ] Locate the permissions screen view code
- [ ] Check button styling implementation
- [ ] Test local build to see if issue reproduces
- [ ] Review button style definitions in codebase
- [ ] Check if other buttons on other screens have same issue

**Related Files**:
- Onboarding permission views in `Muesli/Views/`
- Likely related to screen recording permission screen

---

## Issue 3: Microphone Permission Never Requested from System

**Symptom**: On the microphone permissions page, the app never prompts macOS to request microphone recording permissions. When users click "Open System Settings", Muesli does not appear in the list of apps under Microphone permissions.

**Environment**:
- **Affected**: Official GitHub releases (DMG downloads)
- **Not Affected**: [To be verified in local builds]

**Expected Behavior**: 
- App should trigger system microphone permission prompt
- After prompt (granted or denied), Muesli should appear in System Settings > Privacy & Security > Microphone

**Actual Behavior**: 
- No system prompt appears
- Muesli never shows up in the microphone permissions list in System Settings
- "Check Again" button also appears as blue text instead of styled button (related to Issue 2)

**Impact**: **HIGH** - Users cannot grant microphone permission, blocking core functionality

**Possible Causes**:
- Permission request code not being called in release builds
- Info.plist missing `NSMicrophoneUsageDescription` key
- Code signing/entitlements issue preventing TCC prompt
- Permission manager initialization issue in release builds
- AVAudioEngine setup not triggering permission prompt

**Investigation Needed**:
- [ ] Check Info.plist for microphone usage description
- [ ] Verify entitlements file includes microphone access
- [ ] Review permission request code in PermissionManager
- [ ] Check if permission request is gated behind debug flag
- [ ] Test local release build to isolate if it's CI-specific
- [ ] Compare Info.plist between local build and release DMG

**Related Files**:
- `Muesli/Managers/PermissionManager.swift`
- `Muesli/Views/` - Microphone permission screen
- `Info.plist` or `Muesli.xcodeproj/project.pbxproj` (embedded plist)
- Entitlements file

**Notes**: This issue makes microphone capture completely non-functional in release builds.

---

## Issue 4: Button Styling Inconsistent Between Local and Release Builds

**Status**: ✅ RESOLVED

**Symptom**: Buttons in GitHub release builds use older, less rounded styling instead of the modern "liquid glass" style used in local builds.

**Environment**:
- **Affected**: Official GitHub releases (DMG downloads)
- **Not Affected**: Local builds (via `./scripts/build-and-launch.sh`)

**Root Cause**: SDK version mismatch between local and CI builds.

| Build | SDK | Xcode | Result |
|-------|-----|-------|--------|
| GitHub Release | `macosx15.2` | 16.2 | Old button styling |
| Local Build | `macosx26.2` | 26.2 | Liquid glass styling |

The "liquid glass" button styling is built into the **macOS 26 SDK**. When compiled with macOS 15 SDK (available on `macos-14` runner), SwiftUI's `.borderedProminent` and `.bordered` styles render with the older appearance.

**Fix Applied**:
1. Updated `.github/workflows/release.yml` to use `macos-26` runner
2. Updated `.github/workflows/ci.yml` to use `macos-26` runner  
3. Updated `MACOSX_DEPLOYMENT_TARGET` from 14.0 to 26.0 in project.pbxproj
4. Updated all documentation references to reflect macOS 26 requirement

**Verification**: After rebuilding with `macos-26` runner, buttons will have liquid glass styling matching local builds.

---

## Issue 5: [To be added]

[Description forthcoming]

---

## Debugging Notes

**General approach for release-specific issues**:
1. Download latest release DMG from GitHub
2. Install and test to reproduce
3. Build locally with same configuration
4. Compare behavior
5. Review CI logs for warnings/errors
6. Check Xcode project settings (Debug vs Release configuration)
