# Auto-Reprocess and Second-Pass Finalization Race Condition

**Date**: 2026-02-24
**Category**: Transcription

## Problem Description

When both "Finalize transcript after recording" (second-pass ASR) and "Reprocess after every meeting" (auto-reprocess) preferences are enabled, both launch as concurrent background Tasks after a recording ends. This creates two WhisperKit instances that compete for Apple Neural Engine (ANE) resources and both write to `transcript.md`, with the last writer winning.

## Symptoms/Error Messages

- Automatic reprocessing triggered by meeting end produces an incomplete transcript (missing audio near the end of the recording)
- Manual reprocessing from the ellipsis menu produces the full, correct transcript
- The two paths read from the same audio files on disk, so the audio is complete — the issue is in concurrent transcription processing

## Root Cause Analysis

In `RecordingController.stopRecordingAsync()`, after a recording stops:

1. `launchSecondPassFinalization(for:directory:)` creates a background `Task` that runs `runSecondPassASR` — creates its own WhisperKit instance, reads audio files, writes `transcript.md`
2. `onAutoReprocessRequested?(directory)` triggers `autoReprocessWhenReady(meeting:)` which creates a `Task { @MainActor in ... }` that runs `reprocessTranscript` — creates its own WhisperKit instance, reads the same audio files, writes to the same `transcript.md`

Both tasks run concurrently with no coordination, causing:
- Two separate WhisperKit instances competing for ANE compute resources
- The starved instance (auto-reprocess) produces incomplete/truncated transcription
- Both write to `transcript.md` — last writer wins (race condition)

## Fix Description

1. **Gate auto-reprocess**: In `stopRecordingAsync()`, track whether second-pass finalization was launched with a `secondPassLaunched` flag. Skip `onAutoReprocessRequested` when second-pass is running, since second-pass is a superset of auto-reprocessing.

2. **Defensive guard**: Added `activeSecondPassDirectories: Set<URL>` to `TranscriptionCoordinator` with `markSecondPassActive(for:)` called before launch and `defer` cleanup in `runSecondPassASR` (clears on success, failure, and cancellation). `autoReprocessWhenReady` checks this set and skips with a warning if active.

3. **Failure fallback**: If second-pass fails and the transcript is empty/missing, `launchSecondPassFinalization`'s catch block fires `onAutoReprocessRequested` as recovery.

4. **Manual reprocess**: User-initiated reprocess from the ellipsis menu cancels any running second-pass task via `cancelSecondPassIfRunning()`, so user intent takes precedence without ANE contention.

## Affected Files

- `Muesli/Controllers/RecordingController.swift` - Added `secondPassLaunched` gate in `stopRecordingAsync()`, failure fallback in `launchSecondPassFinalization()`, `cancelSecondPassIfRunning()` method
- `Muesli/Managers/TranscriptionCoordinator.swift` - Added `activeSecondPassDirectories` tracking, `markSecondPassActive(for:)`, `defer` cleanup in `runSecondPassASR`, guard in `autoReprocessWhenReady`
- `Muesli/ViewModels/MuesliViewModel.swift` - Manual reprocess calls `cancelSecondPassIfRunning()` before proceeding

## Prevention/Testing

- Regression tests added in `MuesliTests/TranscriptionCoordinatorTests.swift`:
  - `testAutoReprocessSkippedWhenSecondPassActive`
  - `testAutoReprocessProceedsWhenNoSecondPassActive`
  - `testAutoReprocessAllowedForDifferentDirectory`
- Regression test in `MuesliTests/RecordingControllerTests.swift`:
  - `testCancelSecondPassIfRunningDoesNotCrashWithNoTask`

## Notes

- `RecordingController` is `@MainActor`, so the `secondPassLaunched` flag read/write cannot race.
- The `defer` in `runSecondPassASR` guarantees cleanup on all exit paths (success, throw, cancellation).
- Short recordings that fail the duration gate for second-pass keep `secondPassLaunched = false`, so auto-reprocess runs normally.
- Session resumption is safe: `launchSecondPassFinalization` already cancels any prior task before creating a new one.
