# Mid-Session Permission Recovery

**Date**: 2026-02-18
**Category**: Permissions

## Problem Description

When TCC permissions (screen recording or microphone) were reset while Muesli was running, clicking "New +" to start a recording silently failed — the UI snapped back to idle with no user feedback.

## Symptoms/Error Messages

- User clicks "New +" button to start recording
- UI briefly shows initializing state, then returns to idle
- No error dialog, no toast, no visual feedback
- Console shows `AudioCaptureError.permissionDenied` being caught

```
RecordingController: handleCaptureError - permissionDenied
RecordingSession: showError(.screenRecordingDenied)
// No UI renders the error — .alert modifier only in legacy MainWindow.swift
```

## Root Cause Analysis

Three-part failure:

1. **Error detection worked**: `TapAudioCaptureService.startCapture()` correctly detected missing permission and threw `AudioCaptureError.permissionDenied`.

2. **Error routing was broken**: `RecordingController.handleCaptureError()` called `session.showError(.screenRecordingDenied)`, which sets a published property on the session. However, the `.alert` modifier that observes this property only existed in the **legacy** `MainWindow.swift:32` — NOT in the active `MainWindowView`/`RecordingDetailView` path.

3. **Recovery flow existed but wasn't connected**: The app already had a complete permission recovery flow (`OnboardingView` in `.permissionRecovery` mode) that auto-advances and handles re-granting. But it was only triggered at launch via `AppDelegate.checkPermissionsForRecovery()`.

## Fix Description

Added an `onPermissionRecoveryNeeded` callback on `RecordingController` that fires when permission-denied errors are detected during recording start. `MuesliViewModel` wires it to a new `AppDelegate.requestPermissionRecovery()` method that shows the existing `OnboardingView` in `.permissionRecovery` mode.

Key design decisions:
- **Reuses existing UI**: No new views needed — the OnboardingView permission recovery mode already handles everything
- **Callback pattern**: Consistent with existing RecordingController callbacks (`onSessionStarted`, `onSessionCompleted`, etc.)
- **Guards against double-show**: If recovery window is already visible, the request is ignored
- **Checks both permissions**: Uses `CGPreflightScreenCaptureAccess()` and `AVCaptureDevice.authorizationStatus(for: .audio)` to determine which permissions are missing
- **False negative handling**: If both checks say "granted" (false negative from preflight API), defaults to `missingScreen = true` since screen capture is what actually failed

## Affected Files

- `Muesli/Controllers/RecordingController.swift` — Added `onPermissionRecoveryNeeded` callback; modified `handleCaptureError` and `handleGenericError` to invoke it for permission errors
- `Muesli/MuesliApp.swift` — Added `requestPermissionRecovery(missingScreen:missingMic:)` on AppDelegate
- `Muesli/ViewModels/MuesliViewModel.swift` — Wired callback in init to route to AppDelegate

## Code Snippets

### Before

```swift
// RecordingController.handleCaptureError
private func handleCaptureError(_ error: AudioCaptureError, for session: RecordingSession) {
    let muesliError: MuesliError
    switch error {
    case .permissionDenied, .streamStartFailed:
        muesliError = .screenRecordingDenied
    // ...
    }
    session.showError(muesliError)  // Set but never rendered!
    cleanupFailedSession(session)
}
```

### After

```swift
// RecordingController.handleCaptureError
private func handleCaptureError(_ error: AudioCaptureError, for session: RecordingSession) {
    // ...
    switch error {
    case .permissionDenied, .streamStartFailed:
        let missingScreen = !CGPreflightScreenCaptureAccess()
        let missingMic = AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
        if let callback = onPermissionRecoveryNeeded {
            callback(missingScreen || (!missingScreen && !missingMic), missingMic)
            cleanupFailedSession(session)
            return
        }
    // Fallback to legacy session.showError() if no callback
    }
}
```

## Prevention/Testing

- Regression test: `MuesliTests/RegressionTests.swift` — `testPermissionRecoveryCallbackFiresOnPermissionDenied()`
- Regression test: `MuesliTests/RegressionTests.swift` — `testPermissionRecoveryReusesOnboardingView()`

## Related Issues/PRs

- Related debug log: `2026-01-15_screen-recording-permission-detection.md` (permission detection improvements)

## Notes

- The legacy `MainWindow.swift` `.alert` modifier should eventually be removed or migrated to the active view path
- The `handleGenericError` method also got the same treatment for TCC/permission string-sniffed errors
- `microphoneStartFailed` errors also trigger recovery if mic permission is denied
