# ASR Finalization Missing on Interruption Stop

**Date**: 2026-02-25 10:15
**Category**: Recording

## Problem Description

Meetings that ended through the interruption path (captured app closed / stream interrupted) did not run the same post-stop finalization flow as normal user stop. This caused missing export and missing automatic second-pass/fallback behavior in interrupted sessions.

## Symptoms/Error Messages

- Normal stop sessions ran `secondPass:start ...` and produced finalized transcripts.
- Interrupted sessions saved the recording but skipped export and second-pass eligibility checks.
- Repeated interruption callbacks could schedule duplicate stop tasks.
- Auto-reprocess race guards (`activeSecondPassDirectories`) could remain stale if a second-pass task exited early before entering coordinator reprocessing.

```
[APP] RECORDING_INTERRUPTED ...
recording saved
// no matching automatic finalization/export logs on interrupted path (before fix)
```

## Root Cause Analysis

- `RecordingController.stopRecordingAsync` and `RecordingController.stopRecordingAfterInterruption` had diverged implementations.
- The interruption path stopped transcription and saved transcript blocks, but skipped:
  - export parity
  - second-pass eligibility checks
  - effective live model capture
  - empty-transcript rescue sequencing
- Interruption handling lacked an early idempotency guard, so repeated callbacks could enqueue duplicate stop operations while still in `.recording`.
- Directory active markers were only guaranteed by coordinator `defer` inside `runSecondPassASR`, leaving a gap for early task exits before that call path executed.

## Fix Description

- Refactored both normal-stop and interruption-stop to use a shared completion helper that now owns:
  - second-pass eligibility decision
  - effective live model capture
  - second-pass launch and marker management
  - export invocation
  - completion callback ordering
  - empty-transcript rescue decision
- Added deterministic eligibility helper (`automaticFinalizationDecision`) for direct unit testing.
- Added interruption idempotency guard in `handleCaptureInterrupted` and moved state transition to `.stopping` before scheduling async stop.
- Preserved intentional path difference: interruption stop does **not** call `stopCapture()`.
- Added `TranscriptionCoordinator.clearSecondPassActive(for:)` and controller-side fallback clearing in second-pass task teardown.
- Added interruption lifecycle diagnostic log (`RECORDING_INTERRUPTED`).

## Affected Files

- `Muesli/Controllers/RecordingController.swift` - unified stop finalization flow, interruption idempotency, fallback marker clear, interruption diagnostics
- `Muesli/Managers/TranscriptionCoordinator.swift` - added idempotent marker clear API and reused in `runSecondPassASR`
- `MuesliTests/RecordingControllerTests.swift` - interruption parity coverage and deterministic decision-matrix tests
- `MuesliTests/TranscriptionCoordinatorTests.swift` - marker lifecycle regression coverage

## Code Snippets

### Before

```swift
// interruption path stopped writing and completed session,
// but did not run export/second-pass/rescue parity logic
private func stopRecordingAfterInterruption(for session: RecordingSession) async {
    await transcriptionCoordinator.stopTranscription()
    let directory = try await fileOutputService.stopWriting()
    session.finalizeTranscript()
    try fileOutputService.saveTranscriptBlocks(...)
    onSessionCompleted?(session, session.outputDirectory)
}
```

### After

```swift
private func stopRecordingAfterInterruption(for session: RecordingSession) async {
    // intentionally no stopCapture() on interruption path
    await transcriptionCoordinator.stopTranscription()
    let directory = try await fileOutputService.stopWriting()
    session.finalizeTranscript()
    try fileOutputService.saveTranscriptBlocks(...)
    await completeStopFlow(
        for: session,
        directory: directory,
        interruptionMessage: "Recording saved. \(...)"
    )
}
```

## Prevention/Testing

- Added interruption-path tests for:
  - `stopCapture()` skip behavior
  - duplicate interruption idempotency
  - export parity
  - completion-before-rescue callback ordering
  - resumable completion parity (`session.canResume`)
- Added deterministic decision-matrix test for automatic second-pass eligibility.
- Added coordinator marker-lifecycle tests for clear-after-mark and idempotent clear.

## Related Issues/PRs

- Related debug log: `2026-02-24_reprocessing-race-condition.md`
- Related debug log: `2026-02-24_consolidated-finalization-workflow-migration.md`

## Notes

- Callback sequencing remains canonical: mark completed -> `onSessionCompleted` -> rescue decision.
- Marker clearing is intentionally idempotent on both coordinator and controller paths.
