# Onboarding Flow Specification

This document specifies the expected behavior of Muesli's onboarding flow, including permission handling and state management.

## Overview

The onboarding flow guides first-time users through granting necessary permissions and downloading required models. The flow must be:

1. **Non-intrusive**: System permission prompts should only appear when the user explicitly requests them
2. **Resumable**: Users can quit and return to continue where they left off
3. **Smart**: Already-granted permissions should be automatically detected and skipped

## Onboarding Steps

| Step | Name | Purpose |
|------|------|---------|
| 0 | Welcome | Introduction screen, no permission checks |
| 1 | Screen Recording | Request screen/audio capture permission |
| 2 | Microphone | Request microphone access permission |
| 3 | Model Setup | Download WhisperKit transcription model |
| 4 | LLM Setup | (Optional) Download LLM for transcript refinement |

## Permission Handling Rules

### Rule 1: No Prompts on Welcome Screen

**Requirement**: The system permission dialog must NOT appear until the user clicks "Get Started".

**Implementation**:
- On the welcome screen, only use `CGPreflightScreenCaptureAccess()` for permission checks
- This API checks permission status without triggering the system prompt
- Do NOT call `SCShareableContent` on the welcome screen (it triggers prompts)

### Rule 2: Event-Driven Permission Detection

**Requirement**: Permission changes must be detected through system events, NOT polling.

**Implementation**:
- Use **distributed notifications** to detect TCC permission changes: `com.apple.security.authorization-right-change`
- Use `didBecomeActiveNotification` to detect when user returns from System Settings
- Use `AVCaptureDevice.authorizationStatus(for: .audio)` for microphone checks (never triggers prompts)
- **NEVER use polling timers** - they cause race conditions and unexpected permission prompts

**Why No Polling**:
- Polling calls `SCShareableContent.excludingDesktopWindows()` which triggers permission dialogs
- Creates race conditions where flags aren't set before the next poll
- Distributed notifications are reliable and event-driven
- `AVCaptureDevice.authorizationStatus()` provides synchronous checks without side effects

### Rule 3: Auto-Advance on Return

**Requirement**: When users quit and reopen the app, onboarding should automatically advance past already-completed steps.

**Implementation**:
- Save current step to `UserDefaults` (`onboardingCurrentStep` key)
- On appear, check permissions using synchronous methods to avoid triggering prompts
- Call `advanceBasedOnPermissions()` to skip completed steps
- Auto-advance logic:
  - If screen recording AND microphone granted → go to model setup
  - If only screen recording granted → go to microphone step
  - If no permissions → stay on current step

### Rule 4: Step Persistence

**Requirement**: The current onboarding step should persist across app launches.

**Implementation**:
- Save step on every navigation: `UserDefaults.set(step.rawValue, forKey: "onboardingCurrentStep")`
- Restore on init: `OnboardingStep(rawValue: savedStep) ?? .welcome`
- Clear saved step when onboarding completes

## State Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                         APP LAUNCH                               │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
                    ┌───────────────────────┐
                    │ hasCompletedOnboarding│
                    │      == true?         │
                    └───────────────────────┘
                         │           │
                        Yes          No
                         │           │
                         ▼           ▼
                    ┌────────┐  ┌─────────────────┐
                    │  Main  │  │ Load saved step │
                    │ Window │  │  from defaults  │
                    └────────┘  └─────────────────┘
                                        │
                                        ▼
                              ┌──────────────────┐
                              │ savedStep == 0?  │
                              │   (welcome)      │
                              └──────────────────┘
                                   │        │
                                  Yes       No
                                   │        │
                                   ▼        ▼
                            ┌─────────┐  ┌────────────────────┐
                            │ Show    │  │ Async permission   │
                            │ Welcome │  │ check, then        │
                            │ (no     │  │ advanceBasedOn     │
                            │ prompt) │  │ Permissions()      │
                            └─────────┘  └────────────────────┘
```

## Permission Check APIs

| API | Triggers Prompt? | Reliable? | Use Case |
|-----|------------------|-----------|----------|
| `CGPreflightScreenCaptureAccess()` | No | No (ad-hoc signing) | Initial checks only |
| `CGRequestScreenCaptureAccess()` | Yes | N/A | **ONLY** when user clicks "Grant Permission" button |
| `SCShareableContent.excludingDesktopWindows()` | Only if not granted | Yes | **AVOID** - use only for explicit permission requests |
| `AVCaptureDevice.authorizationStatus(for: .audio)` | No | Yes | **PREFERRED** - use for all microphone checks |
| `AVCaptureDevice.requestAccess(for: .audio)` | Yes (if undetermined) | Yes | **ONLY** when user clicks "Grant Permission" button |

**Critical Rule**: Use `AVCaptureDevice.authorizationStatus()` for all permission checks during monitoring. Never use `SCShareableContent` in loops, timers, or callbacks - it triggers permission prompts.

## Permission Monitoring Architecture

### Event-Driven Design

Permission changes are detected through macOS system events, **not polling**:

```
┌─────────────────────────────────────────────────────────────────┐
│                   Permission Change Sources                      │
├─────────────────────────────────────────────────────────────────┤
│ 1. Distributed Notification                                     │
│    - Event: com.apple.security.authorization-right-change       │
│    - Fires when: TCC database changes (permission granted/denied)│
│    - Handler: checkAndNotifyPermissionChangesSynchronously()    │
│                                                                  │
│ 2. App Activation Notification                                  │
│    - Event: NSApplication.didBecomeActiveNotification           │
│    - Fires when: User returns from System Settings              │
│    - Handler: refreshPermissionsAsync() (only after onboarding) │
│                                                                  │
│ 3. Manual Checks (Button Clicks)                                │
│    - Trigger: User clicks "Check Again" button                  │
│    - Handler: refreshPermissions() (synchronous)                │
└─────────────────────────────────────────────────────────────────┘
```

### Synchronous vs Asynchronous Checks

- **`refreshPermissions()`** (synchronous):
  - Uses `CGPreflightScreenCaptureAccess()` and `AVCaptureDevice.authorizationStatus()`
  - Never triggers permission prompts
  - Safe to call in loops, callbacks, and monitoring
  - Use for: button-triggered checks, monitoring callbacks, onboarding screens

- **`refreshPermissionsAsync()`** (asynchronous):
  - Uses `SCShareableContent.excludingDesktopWindows()`
  - **CAN trigger screen recording prompt if permission not granted**
  - Only use: in `didBecomeActiveNotification` after onboarding complete
  - **NEVER use**: in onboarding screens, timers, polling loops, or distributed notification handlers

### Implementation in PermissionManager

```swift
// ✅ CORRECT: Event-driven monitoring
func startMonitoringPermissions() {
    // Listen for TCC changes
    distributedCenter.addObserver(
        forName: NSNotification.Name("com.apple.security.authorization-right-change"),
        object: nil,
        queue: .main
    ) { [weak self] _ in
        // Use synchronous check - never triggers prompts
        self?.checkAndNotifyPermissionChangesSynchronously()
    }
    
    // ❌ NO POLLING TIMER - removed to prevent unwanted prompts
}

// ✅ Synchronous check for monitoring
private func checkAndNotifyPermissionChangesSynchronously() {
    let (newScreen, newMic) = refreshPermissions()  // Safe, synchronous
    if newScreen != screenRecordingGranted || newMic != microphoneGranted {
        permissionDidChange?(newScreen, newMic)
    }
}

// ❌ WRONG: Polling with async check
// Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
//     await self?.refreshPermissionsAsync()  // Would trigger prompts!
// }
```

## Key Files

| File | Responsibility |
|------|----------------|
| `OnboardingView.swift` | UI and step navigation |
| `PermissionManager.swift` | Permission checking and requesting |
| `MuesliViewModel.swift` | Permission state properties |
| `AppStorageKeys.swift` | UserDefaults key constants |

## Regression Test Cases

### Test: No Prompt on Welcome Screen
- Launch app with no permissions granted
- Verify welcome screen appears
- Verify NO system permission dialog appears
- Only after clicking "Get Started" should permission UI appear

### Test: No Prompt on Microphone Screen
**Critical**: This test verifies the fix for the polling timer bug (Jan 18, 2026)
- Launch app, click "Get Started"
- Grant screen recording permission
- Advance to microphone screen
- **Verify NO screen recording dialog appears**
- Only after clicking "Grant Microphone Access" should microphone dialog appear

### Test: Auto-Advance After Permission Grant
- Grant screen recording permission
- Quit and reopen app
- Verify app auto-advances to microphone step (not stuck on screen recording)

### Test: Step Persistence
- Navigate to model setup step
- Quit app
- Reopen app
- Verify app resumes at model setup step

### Test: Complete Flow Skip
- Grant all permissions and download model
- Reset `hasCompletedOnboarding` but keep permissions
- Reopen app
- Verify onboarding auto-completes or advances to final step

## Critical: No Polling Timers

### Problem
Using `Timer.scheduledTimer()` to poll for permission changes causes:
1. **Unwanted permission prompts** - calling `SCShareableContent` in a loop triggers dialogs
2. **Race conditions** - flags may not be set before the next poll fires
3. **Poor user experience** - dialogs appear at unexpected times

### Impact
A polling timer that calls `refreshPermissionsAsync()` will trigger the screen recording permission dialog on the microphone screen, breaking the onboarding flow.

### Solution
Use **event-driven architecture only**:
1. **Distributed notifications** for TCC permission changes
2. **App activation notifications** for returning from System Settings
3. **Synchronous checks** in all callbacks (never `SCShareableContent` in loops)

### Affected Code
- `PermissionManager.startMonitoringPermissions()` - Uses distributed notifications, NO polling timer
- `PermissionManager.checkAndNotifyPermissionChangesSynchronously()` - Synchronous check only
- `OnboardingView` button handlers - Use `refreshPermissions()`, not `refreshPermissionsAsync()`

## Critical: AVCaptureDevice and Permission Prompts

### Problem
`AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, ...)` can trigger the microphone permission prompt on macOS, even when only enumerating devices.

### Impact
If `MicrophoneManager.refreshDevices()` is called during app init (before onboarding), the microphone permission prompt appears on the welcome screen instead of the microphone permission screen.

### Solution
1. **Defer device enumeration**: Do NOT call `refreshDevices()` in `MicrophoneManager.init()`
2. **Guard all device access**: Check `AVCaptureDevice.authorizationStatus(for: .audio) == .authorized` before any `DiscoverySession` call
3. **Refresh after permission grant**: Call `microphoneManager.refreshDevices()` in `requestMicrophonePermission()` after permission is granted
4. **Handle returning users**: If permission is already granted at init, refresh devices immediately

### Affected Methods
- `MicrophoneManager.init()` - No longer calls `refreshDevices()`
- `MicrophoneManager.refreshDevices()` - Guards with permission check
- `MicrophoneManager.currentDefaultDevice` - Guards with permission check
- `MicrophoneManager.setSystemDefaultMicrophone()` - Guards with permission check
- `MuesliViewModel.requestMicrophonePermission()` - Calls `refreshDevices()` after grant
- `MuesliViewModel.init()` - Calls `refreshDevices()` if permission already granted

## Critical: SCShareableContent in Notification Observers

### Problem
`SCShareableContent.excludingDesktopWindows()` triggers the screen recording permission prompt. If called from notification observers or callbacks, the prompt appears at unexpected times.

### Solution
1. In `didBecomeActiveNotification`, check `hasCompletedOnboarding` before calling `refreshPermissionsAsync()`
2. In distributed notification observers, **always use synchronous checks** (`refreshPermissions()`)
3. **Never call `refreshPermissionsAsync()` in callbacks, loops, or timers**

Example from `PermissionManager.init()`:
```swift
guard UserDefaults.standard.bool(forKey: AppStorageKeys.hasCompletedOnboarding) else {
    return  // Skip during onboarding - SCShareableContent would trigger prompt
}
_ = await self?.refreshPermissionsAsync()
```

## Debugging Onboarding Issues

Muesli includes a diagnostic logging system specifically designed to debug onboarding issues in release builds. See [spec/diagnostic_logging.md](diagnostic_logging.md) for the full specification.

### Using Diagnostic Logs

1. **Access Debug Info Panel**: Menu Bar → "Debug Info..." (available during onboarding)
2. **View permission states**: Panel shows raw `authorizationStatus` values
3. **Open logs**: Click "Open in Finder" to access log files
4. **Search for issues**:
   ```bash
   grep PERMISSION ~/Library/Application\ Support/Muesli/Logs/*.log
   grep ONBOARDING ~/Library/Application\ Support/Muesli/Logs/*.log
   ```

### Expected Log Output

When permission is requested successfully:
```
[PERMISSION] requestMicrophonePermission called. Bundle: com.muesli.app
[PERMISSION] NSMicrophoneUsageDescription: Muesli needs Microphone access...
[PERMISSION] authorizationStatus(for: .audio) = 0 (notDetermined)
[PERMISSION] Status is notDetermined, calling requestAccess...
[PERMISSION] requestAccess returned: true
```

When there's a problem:
- `NSMicrophoneUsageDescription: MISSING` → Info.plist not embedded correctly
- `authorizationStatus = 2 (denied)` → Permission previously denied
- No log entries after button tap → Button handler not executing

### Common Issue: Running Wrong Binary

**Symptom**: Permission detection appears broken after code changes, but you're certain the fix should work.

**Root Cause**: macOS may launch an installed version from `/Applications/` instead of the freshly built version in `~/Library/Developer/Xcode/DerivedData/`.

**Solution**:
1. Kill the app: `killall Muesli`
2. Check which version is running: `ps aux | grep Muesli.app | grep -v grep`
3. If path shows `/Applications/Muesli.app`, delete it: `rm -rf /Applications/Muesli.app`
4. Launch the debug build: `open ~/Library/Developer/Xcode/DerivedData/Muesli-*/Build/Products/Debug/Muesli.app`

**Prevention**: After building, always verify the correct binary is running by checking the process path.

## Strict Step-Based Guards (Critical)

### Rule: Step 0 (Welcome) is SAFE-ONLY

**Requirement**: The welcome screen (step 0) must NEVER trigger any async permission checks.

**Implementation in `PermissionManager.handleDidBecomeActive()`**:

```swift
if hasCompletedOnboarding {
    // Post-onboarding: safe to use async refresh
    _ = await refreshPermissionsAsync()
} else if currentStep == 0 {
    // STRICT GUARD: Welcome screen - ONLY safe sync check, NO async
    _ = refreshPermissions()
} else if awaitingScreenRecordingFromSettings {
    // User returned from System Settings - safe to check async
    awaitingScreenRecordingFromSettings = false
    _ = await checkScreenRecordingPermissionAsync()
    permissionDidChange?(screenRecordingGranted, microphoneGranted)
} else if awaitingMicrophoneFromSettings {
    // User returned from System Settings - mic check is always safe
    awaitingMicrophoneFromSettings = false
    _ = refreshPermissions()
    permissionDidChange?(screenRecordingGranted, microphoneGranted)
} else {
    // On permission screens but not awaiting settings return
    _ = refreshPermissions()
}
```

### Awaiting Settings Pattern

When the user clicks "Open System Settings", we mark that we're awaiting their return:

1. **Screen Recording**: `markAwaitingScreenRecordingFromSettings()`
2. **Microphone**: `markAwaitingMicrophoneFromSettings()`

When the app becomes active and an awaiting flag is set, we use the appropriate check and clear the flag.

### Verify After Request Pattern

When the user clicks "Grant Permission", we verify the permission immediately:

```swift
Button("Grant System Audio Access") {
    screenRecordingRequested = true
    Task {
        let granted = await viewModel.requestScreenRecordingPermission()
        if granted {
            withAnimation { setStep(.microphone) }
        }
        AppDelegate.shared?.bringOnboardingWindowToFront()
    }
}
```

### System Audio Permission Caching

`refreshPermissions()` should not use `CGPreflightScreenCaptureAccess()` to set
System Audio Recording because that API reflects the Screen Recording bucket and
can return true even when System Audio Recording is not granted. We only update
the system-audio permission flag from explicit Core Audio tap probes and cache
the result.

## TCC Debugging

### Bundle ID Logging

The `PermissionManager` logs the bundle ID on init for debugging TCC issues. This is captured in both console output and the diagnostic log files:

```swift
init() {
    if let bundleID = Bundle.main.bundleIdentifier {
        print("[PermissionManager] Bundle ID: \(bundleID)")
    }
    // ...
}
```

Additionally, the `DiagnosticLogger` captures:
- Bundle ID on every permission request
- Info.plist permission description keys (or "MISSING" if absent)
- Raw `authorizationStatus` values with human-readable names

This helps identify issues where TCC permissions are granted to a different bundle ID (e.g., when running debug vs release builds, or different bundle IDs on feature branches).

### Diagnostic Log Location

```
~/Library/Application Support/Muesli/Logs/muesli-YYYY-MM-DD.log
```

See [spec/diagnostic_logging.md](diagnostic_logging.md) for complete logging specification.

## Manual Testing Checklist

Since system permission APIs cannot be unit tested (they trigger real dialogs), use this checklist to verify the onboarding flow works correctly:

### Pre-Test Setup
```bash
# Reset all permissions for Muesli
tccutil reset ScreenCapture com.muesli.app
tccutil reset Microphone com.muesli.app

# Clear onboarding state
defaults delete com.muesli.app hasCompletedOnboarding
defaults delete com.muesli.app onboardingCurrentStep
```

### Test Scenarios

**1. Welcome Screen - No Dialog**
- [ ] Launch app after reset
- [ ] Verify welcome screen appears
- [ ] Wait 10 seconds - NO permission dialog should appear
- [ ] Click "Get Started" to proceed

**2. Screen Recording Grant Flow**
- [ ] On screen recording screen, click "Grant Screen Recording Access"
- [ ] System dialog appears
- [ ] Click "Allow" in system dialog
- [ ] Verify auto-advance to microphone screen

**3. Screen Recording Deny Flow**
- [ ] On screen recording screen, click "Grant Screen Recording Access"
- [ ] System dialog appears
- [ ] Click "Don't Allow"
- [ ] Verify app returns to screen recording screen with "Open System Settings" option
- [ ] Verify NO repeated permission dialogs (no loop)

**4. Open System Settings Flow**
- [ ] On screen recording screen, click "Open System Settings"
- [ ] System Settings opens to Screen Recording pane
- [ ] Toggle permission ON for Muesli
- [ ] Switch back to Muesli
- [ ] Verify auto-advance to microphone screen

**5. Microphone Grant Flow**
- [ ] On microphone screen, click "Grant Microphone Access"
- [ ] System dialog appears
- [ ] Click "OK"
- [ ] Verify auto-advance to model setup

**6. Resume After Quit**
- [ ] Complete steps 1-2 (grant screen recording only)
- [ ] Quit the app (Cmd+Q)
- [ ] Relaunch the app
- [ ] Verify app resumes on microphone screen (step 2)
- [ ] Verify NO permission dialogs on launch

**7. Already Granted Permissions**
- [ ] Grant both permissions via System Settings before launching
- [ ] Launch app
- [ ] Click "Get Started" on welcome screen
- [ ] Verify app skips directly to model setup (step 3)

### Expected Console Output

Watch for these log messages:
```
[PermissionManager] Bundle ID: com.muesli.app
```

If you see a different bundle ID, TCC permissions may not work correctly.

## Change History

| Date | Change | Reason |
|------|--------|--------|
| 2026-01-15 | Use sync check on welcome, async elsewhere | Prevent premature permission prompts |
| 2026-01-15 | Add async check on step change | Reliable detection after granting |
| 2026-01-15 | Defer MicrophoneManager.refreshDevices() | AVCaptureDevice.DiscoverySession triggers mic permission prompt |
| 2026-01-16 | Guard didBecomeActiveNotification observer | SCShareableContent triggers screen recording prompt |
| 2026-01-16 | Update guard to allow refresh during onboarding | Allow auto-detection when currentStep > 0 (not on welcome screen) |
| 2026-01-18 | **Remove polling timer, use event-driven architecture** | **Polling timer caused screen recording dialog on microphone screen** |
| 2026-01-18 | Always use synchronous checks in callbacks | Prevents SCShareableContent from triggering prompts in loops |
| 2026-01-18 | Implement strict step-based guards (step==0 safe-only) | Ensures welcome screen never triggers async checks |
| 2026-01-18 | Add awaiting settings pattern | Reliably detect permission changes when user returns from Settings |
| 2026-01-18 | Add verify after request pattern | Immediately detect permission grant without polling |
| 2026-01-18 | Add optimistic OR for sync checks | Allows sync check to detect newly-granted permissions |
| 2026-01-18 | Add bundle ID logging | Aids TCC debugging with different bundle IDs |
| 2026-01-20 | Add diagnostic logging integration | File-based logs for debugging release build issues |