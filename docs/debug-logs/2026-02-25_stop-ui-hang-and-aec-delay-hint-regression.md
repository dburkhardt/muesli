# Stop UI Hang + AEC Delay-Hint Regression

**Date**: 2026-02-25 15:20
**Category**: Recording

## Problem Description

Two regressions were reported together:
- Stopping a recording appeared to hang with no clear end-of-recording indicator, and the UI jumped straight to the final refined transcript.
- AEC quality regressed with repeated non-converging sessions.

## Symptoms/Error Messages

- User-visible behavior:
  - Stop action looked stalled for several seconds.
  - No visible "reprocessing/finalizing" feedback during stop in the detail view.
  - Transcript view jumped directly to finalized/refined output.
- Diagnostics showed second-pass did complete:

```text
[2026-02-25 14:58:20.707] [STABILIZER] secondPass:scheduled dir=...
[2026-02-25 14:58:20.764] [STABILIZER] secondPass:start model=large-v3-v20240930_turbo
[2026-02-25 14:58:40.016] [STABILIZER] secondPass:done model=large-v3-v20240930_turbo blocks=7 segments=12 duration=19.04s
```

- Same session showed AEC drift/non-convergence indicators:

```text
[AEC] ... streamDelay=0ms ...
[AEC] DELAY_MISMATCH: |sync-bridge|=104ms sustained ...
[AEC] AEC_NONCONVERGING: ERLE=0.2dB ...
```

## Root Cause Analysis

1. Stop UX issue:
- `TranscriptionCoordinator` is `@MainActor`.
- Second-pass/reprocess setup still executed heavy WhisperKit post-processing orchestration from MainActor paths.
- In some runs this delayed UI state progression enough that users perceived a hang and missed the transition indicator.

2. AEC regression:
- `AudioWorker` fed a hardcoded `setStreamDelayMs(0)` every frame.
- That removed synchronizer-derived delay hints and correlated with sustained `DELAY_MISMATCH` + `AEC_NONCONVERGING` in recent sessions.

## Fix Description

- Kept WhisperKit post-processing ASR collection off the main actor:
  - Added detached helper flow in `TranscriptionCoordinator` for second-pass and manual reprocess collection.
  - Removed `@MainActor` isolation from `TranscriptionService.initialize(modelPath:)` so detached setup remains valid.
- Restored synchronizer-based AEC delay hints:
  - `AudioWorker` now feeds `coarseDelayMs` (fallback `seededDelayMs`), clamped to `[0, 500]`.
- Improved stop UX feedback:
  - Added a stopping/finalizing banner and spinner state in `RecordingDetailView` while `session.state == .stopping`.

## Affected Files

- `Muesli/Managers/TranscriptionCoordinator.swift` - detached post-processing collection helper for second-pass/reprocess
- `Muesli/Services/TranscriptionService.swift` - removed `@MainActor` from model initialization
- `Muesli/Services/AudioWorker.swift` - synchronizer-derived `setStreamDelayMs` hints
- `Muesli/Views/RecordingDetailView.swift` - explicit stopping/finalizing indicator
- `MuesliTests/CoreAudioTapTests.swift` - regression coverage for delay hint propagation

## Code Snippets

### Before

```swift
let delaySet = aecProcessor.setStreamDelayMs(0)
```

### After

```swift
let coarseDelayMs = synchronizer.coarseDelayMs
let seededDelayMs = synchronizer.seededDelayMs
let streamDelayHintMs = coarseDelayMs > 0 ? coarseDelayMs : max(seededDelayMs, 0)
let boundedStreamDelayMs = min(max(streamDelayHintMs, 0), 500)
let delaySet = aecProcessor.setStreamDelayMs(boundedStreamDelayMs)
```

## Prevention/Testing

- Added regression test:
  - `MuesliTests/CoreAudioTapTests.swift`
  - `testAudioWorkerFeedsSynchronizerDelayHintToAEC()`
- Validation run:
  - `CoreAudioTapTests`, `RecordingControllerTests`, and `TranscriptionCoordinatorTests`
  - Result: pass (119 tests, 0 failures)

## Related Issues/PRs

- Related debug log: `2026-02-25_second-pass-finalization-stopflow-latency.md`
- Related debug log: `2026-02-25_reprocessing-ui-stuck-stale-selection.md`
- Related debug log: `2026-02-24_aec_convergence_freeze_reset_fix.md`

## Notes

- This fix targets both perceived stop-flow responsiveness and AEC observability correctness.
- If future sessions still show stop latency, add explicit stop-phase timing diagnostics around:
  - `audioCaptureService.stopCapture()`
  - `transcriptionCoordinator.stopTranscription()`
  - `fileOutputService.stopWriting()`
