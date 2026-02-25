# installTap NSException Crash During Mic Start

**Date**: 2026-02-24 21:15
**Category**: Audio

## Problem Description

Muesli crashed with `SIGABRT` when starting microphone capture. The crash happened inside `AVAudioNode.installTap` during `TapAudioCaptureService.startMicrophoneCapture()`.

## Symptoms/Error Messages

- App terminated immediately when starting or re-starting recording in certain microphone/device states.
- Crash reporter showed process abort (`Abort trap: 6`) rather than a recoverable capture error.
- No user-facing warning could be shown because the process terminated before Swift error handling ran.

```
SIGABRT — abort() called
AVAudioEngineImpl::InstallTapOnNode(...)
-[AVAudioNode installTapOnBus:bufferSize:format:block:]
TapAudioCaptureService.startMicrophoneCapture()
TapAudioCaptureService.startCapture()
RecordingController.startRecordingAsync(for:)
```

## Root Cause Analysis

- `AVAudioNode.installTap` can throw Objective-C `NSException` under invalid/unstable engine state.
- Swift `do/catch` cannot catch Objective-C exceptions.
- Existing code validated `inputFormat` values but did not protect the `installTap` call itself.
- Result: uncaught `NSException` aborted the process.

## Fix Description

- Added an Objective-C helper (`ObjCTryCatch`) that executes a block in `@try/@catch` and returns `NSException?`.
- Wrapped both primary and fallback `installTap` call sites with `ObjCTryCatch`.
- Converted caught exceptions into `AudioCaptureError.microphoneStartFailed(NSError(...))` so startup failures flow through existing cleanup/error paths instead of crashing.
- Tightened `RecordingController` classification so `microphoneStartFailed` maps to `microphoneDenied` only when microphone permission is actually missing; otherwise it maps to `captureStartFailed`.

## Affected Files

- `Muesli/Helpers/ObjCExceptionCatcher.h` - Added ObjC exception-catcher declaration for Swift bridge.
- `Muesli/Helpers/ObjCExceptionCatcher.m` - Implemented `@try/@catch` wrapper around callback block execution.
- `Muesli/Muesli-Bridging-Header.h` - Imported catcher header into Swift target.
- `Muesli/Services/TapAudioCaptureService.swift` - Wrapped both `installTap` calls and converted exceptions to Swift errors.
- `Muesli/Controllers/RecordingController.swift` - Permission-gated `microphoneStartFailed` error mapping/recovery behavior.
- `MuesliTests/RegressionTests.swift` - Added source-level regression tests for wrappers and classification guard.
- `Muesli.xcodeproj/project.pbxproj` - Added new helper files to project/groups/target sources.

## Code Snippets

### Before

```swift
inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, time in
    self?.handleMicrophoneBuffer(buffer, time: time)
}
```

### After

```swift
if let installException = ObjCTryCatch({
    inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, time in
        self?.handleMicrophoneBuffer(buffer, time: time)
    }
}) {
    throw AudioCaptureError.microphoneStartFailed(
        NSError(domain: "TapAudioCapture.InstallTapException", code: -4, userInfo: [
            NSLocalizedDescriptionKey: "installTap failed: \(installException.name.rawValue)"
        ])
    )
}
```

## Prevention/Testing

- Added regression tests in `MuesliTests/RegressionTests.swift`:
  - `testStartMicrophoneCaptureWrapsInstallTapCallsInObjCTryCatch()`
  - `testHandleCaptureErrorPermissionGatesMicrophoneStartFailureMapping()`
- Preserved existing startup cleanup path (`startCapture` catch branch) so partial-start resources are cleaned when tap install fails.

## Related Issues/PRs

- Regression tests: `MuesliTests/RegressionTests.swift`
- Related debug logs:
  - `2026-02-17_mic-sample-rate-race.md`
  - `2026-02-24_aec_convergence_non48khz_mic.md`

## Notes

- This fix targets the `installTap` crash path specifically.
- Follow-up hardening (tracked separately): protect other AVAudioEngine operations (`removeTap`, `engine.stop`) and tighten partial-start cleanup in `cleanupFailedSession()`.
