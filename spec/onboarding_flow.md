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

### Rule 2: Reliable Detection After Welcome

**Requirement**: Once past the welcome screen, permission status must be accurately detected.

**Implementation**:
- Use `SCShareableContent.excludingDesktopWindows()` for reliable screen recording detection
- `CGPreflightScreenCaptureAccess()` is unreliable with ad-hoc code signing
- `SCShareableContent` only triggers a prompt when permission is NOT granted
- If permission IS already granted, `SCShareableContent` returns successfully without any prompt

### Rule 3: Auto-Advance on Return

**Requirement**: When users quit and reopen the app, onboarding should automatically advance past already-completed steps.

**Implementation**:
- Save current step to `UserDefaults` (`onboardingCurrentStep` key)
- On appear, if saved step > welcome:
  - Use async permission check (`refreshPermissionsAsync()`)
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
| `CGPreflightScreenCaptureAccess()` | No | No (ad-hoc signing) | Welcome screen only |
| `CGRequestScreenCaptureAccess()` | Yes | N/A | Requesting permission |
| `SCShareableContent.excludingDesktopWindows()` | Only if not granted | Yes | After welcome screen |
| `AVCaptureDevice.authorizationStatus(for: .audio)` | No | Yes | Microphone check |
| `AVCaptureDevice.requestAccess(for: .audio)` | Yes (if undetermined) | Yes | Microphone request |

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
`SCShareableContent.excludingDesktopWindows()` triggers the screen recording permission prompt. If called from `didBecomeActiveNotification` during onboarding, the prompt appears on the welcome screen.

### Solution
In `PermissionManager.init()`, the `didBecomeActiveNotification` observer must check `hasCompletedOnboarding` BEFORE calling `refreshPermissionsAsync()`:

```swift
guard UserDefaults.standard.bool(forKey: AppStorageKeys.hasCompletedOnboarding) else {
    return  // Skip during onboarding - SCShareableContent would trigger prompt
}
_ = await self?.refreshPermissionsAsync()
```

## Debugging Onboarding Issues

### Common Issue: Running Wrong Binary

**Symptom**: Permission detection appears broken after code changes, but you're certain the fix should work.

**Root Cause**: macOS may launch an installed version from `/Applications/` instead of the freshly built version in `~/Library/Developer/Xcode/DerivedData/`.

**Solution**:
1. Kill the app: `killall Muesli`
2. Check which version is running: `ps aux | grep Muesli.app | grep -v grep`
3. If path shows `/Applications/Muesli.app`, delete it: `rm -rf /Applications/Muesli.app`
4. Launch the debug build: `open ~/Library/Developer/Xcode/DerivedData/Muesli-*/Build/Products/Debug/Muesli.app`

**Prevention**: After building, always verify the correct binary is running by checking the process path.

## Change History

| Date | Change | Reason |
|------|--------|--------|
| 2026-01-15 | Use sync check on welcome, async elsewhere | Prevent premature permission prompts |
| 2026-01-15 | Add async check on step change | Reliable detection after granting |
| 2026-01-15 | Defer MicrophoneManager.refreshDevices() | AVCaptureDevice.DiscoverySession triggers mic permission prompt |
| 2026-01-16 | Guard didBecomeActiveNotification observer | SCShareableContent triggers screen recording prompt |
| 2026-01-16 | Update guard to allow refresh during onboarding | Allow auto-detection when currentStep > 0 (not on welcome screen) |