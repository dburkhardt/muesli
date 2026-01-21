# Screen Recording Permission Detection Unreliable

**Date**: 2026-01-15 10:30
**Category**: Permissions

## Problem Description

Muesli's onboarding flow was stuck showing "screen recording permission not granted" even after users granted permission in System Settings and returned to the app. The permission check reported false negatives, blocking users from completing onboarding.

## Symptoms/Error Messages

**User-visible behavior:**
- User clicks "Grant Permission" in onboarding
- System Settings opens to Screen & System Audio Recording
- User enables Muesli and returns to app (app becomes active)
- Onboarding still shows permission as not granted
- User is stuck in onboarding loop

**Console logs:**
```
[PermissionManager] Screen recording permission check: false
[PermissionManager] CGPreflightScreenCaptureAccess returned: false
```

**Reproduction:**
1. Fresh install on macOS 14+ with ad-hoc signing (development build)
2. Launch app for first time
3. Grant screen recording permission in System Settings
4. Return to app - permission still shows as denied

## Root Cause Analysis

The root cause was using `CGPreflightScreenCaptureAccess()` for synchronous permission checking. This API has known reliability issues with ad-hoc signed applications (development builds):

1. **Ad-hoc signing limitation**: `CGPreflightScreenCaptureAccess()` returns false even when permission IS granted if the app is ad-hoc signed rather than notarized with a Developer ID
2. **Synchronous check unreliable**: The function checks code signing state, not actual TCC database state
3. **Async check required**: `SCShareableContent.excludingDesktopWindows()` is the reliable way to check permissions - it actually tests if the API works

**Why this matters:**
- Development builds always use ad-hoc signing
- Only release builds are notarized with Developer ID
- Most debugging/testing happens with ad-hoc signed builds
- This made the onboarding flow unusable during development

**Apple Documentation:**
> "CGPreflightScreenCaptureAccess checks if the current process has been granted screen recording permission. Note that this may not be accurate for ad-hoc signed applications."

## Fix Description

Replaced synchronous `CGPreflightScreenCaptureAccess()` with cached async permission state:

1. **Cache async result**: Store the result from `SCShareableContent` check in `screenRecordingGranted` property
2. **Return cached value**: `hasScreenRecordingPermission` returns the cached value instead of calling CGPreflight
3. **Refresh on activation**: When app becomes active, call async `refreshPermissionsAsync()` which uses reliable `SCShareableContent` check
4. **Update cached state**: Async check updates `screenRecordingGranted` which flows to `hasScreenRecordingPermission`

**Why this works:**
- `SCShareableContent.excludingDesktopWindows()` actually attempts to access screen content
- If permission is granted, the call succeeds (no exception thrown)
- If permission is denied, the call throws an exception
- This tests actual TCC database state, not code signing
- Works correctly with both ad-hoc and Developer ID signing

## Affected Files

- `Muesli/Utilities/PermissionManager.swift` - Changed `hasScreenRecordingPermission` to return cached async result
- `Muesli/ViewModels/MuesliViewModel.swift` - Use `refreshPermissionsAsync()` in `didBecomeActiveNotification` observer
- `Muesli/Views/OnboardingView.swift` - Async permission refresh on permission screens

## Code Snippets

### Before

```swift
// PermissionManager.swift
var hasScreenRecordingPermission: Bool {
    // BROKEN: Unreliable with ad-hoc signing
    CGPreflightScreenCaptureAccess()
}

// MuesliViewModel.swift - didBecomeActiveNotification observer
NotificationCenter.default.addObserver(
    forName: NSApplication.didBecomeActiveNotification,
    ...
) { _ in
    Task { @MainActor in
        self?.refreshPermissions()  // Called sync version
    }
}

func refreshPermissions() {
    hasScreenRecordingPermission = permissionManager.hasScreenRecordingPermission
    // ^ This uses CGPreflight which returns false incorrectly
}
```

### After

```swift
// PermissionManager.swift
@MainActor
@Observable
final class PermissionManager {
    private var screenRecordingGranted: Bool = false  // Cached async result
    
    var hasScreenRecordingPermission: Bool {
        // FIXED: Return cached value from reliable async check
        screenRecordingGranted
    }
    
    func checkScreenRecordingPermissionAsync() async -> Bool {
        do {
            // This is the RELIABLE way to check - actually tests if API works
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            screenRecordingGranted = true
            return true
        } catch {
            screenRecordingGranted = false
            return false
        }
    }
}

// MuesliViewModel.swift - didBecomeActiveNotification observer
NotificationCenter.default.addObserver(
    forName: NSApplication.didBecomeActiveNotification,
    ...
) { _ in
    Task { @MainActor in
        // Guard check added later to prevent prompt during onboarding
        guard UserDefaults.standard.bool(forKey: AppStorageKeys.hasCompletedOnboarding) else {
            return
        }
        await self?.refreshPermissionsAsync()  // Use async version
    }
}

func refreshPermissionsAsync() async {
    hasScreenRecordingPermission = await permissionManager.checkScreenRecordingPermissionAsync()
    // ^ This uses SCShareableContent which is reliable
}
```

## Prevention/Testing

**Regression tests added:**
- `MuesliTests/RegressionTests.swift`:
  - `testHasScreenRecordingPermissionReturnsCachedValue()` - Verifies cached value is returned
  - `testDidBecomeActiveUsesAsyncPermissionCheck()` - Verifies async check on app activation
  - `testPermissionCheckDoesNotBlockOnboardingWhenGranted()` - Verifies permission detection works

**Documentation updated:**
- `AGENTS.md` - Added pitfall documentation about CGPreflightScreenCaptureAccess unreliability
- Added note to use `checkScreenRecordingPermissionAsync()` for reliable detection

**Architecture change:**
- All permission checks now use async-first pattern
- Sync `hasScreenRecordingPermission` returns cached state from last async check
- UI polls async checks when permission status matters (onboarding screens)

## Related Issues/PRs

- Regression test: `MuesliTests/RegressionTests.swift` - `testHasScreenRecordingPermissionReturnsCachedValue()`
- Follow-up fix (2026-01-16): Added onboarding guard to prevent prompt on welcome screen
- Related pitfall: AGENTS.md "TCC Permissions" section

## Notes

**Additional findings:**

1. **SCShareableContent triggers prompt**: Calling `SCShareableContent.excludingDesktopWindows()` WILL trigger the permission prompt if not granted. Must guard this call appropriately (don't call during onboarding before user clicks "Grant Permission").

2. **Follow-up fix required**: Initial fix still called `refreshPermissionsAsync()` on welcome screen, triggering prompt too early. Added `hasCompletedOnboarding` guard to observer (2026-01-16).

3. **Safe vs unsafe APIs**:
   - **Safe** (no prompt): `CGPreflightScreenCaptureAccess()` - but unreliable with ad-hoc signing
   - **Unsafe** (triggers prompt): `SCShareableContent.excludingDesktopWindows()` - reliable but prompts
   - **Solution**: Use async check only when appropriate (after user interaction, post-onboarding)

4. **Development workflow impact**: This bug blocked all local development testing of the onboarding flow. The fix was critical for developer productivity.

5. **Release builds work differently**: Production builds with Developer ID notarization don't have this issue - CGPreflight works correctly. This is purely a development/ad-hoc signing problem.

**Known limitations:**
- Still need to call async check periodically to keep cache fresh
- Timing window between permission grant and cache update (onboarding polls every 0.5s)
- Must be careful not to trigger prompt prematurely during onboarding
