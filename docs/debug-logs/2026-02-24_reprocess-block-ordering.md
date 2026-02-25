# Reprocess Transcript Block Ordering Lost

**Date**: 2026-02-24 22:30
**Category**: Transcription

## Problem Description

Post-meeting reprocessing (automatic or manual) produced transcripts where all "Them" blocks appeared first, followed by all "Me" blocks. The chronological interleaving between speakers was completely lost.

## Symptoms/Error Messages

- After a meeting ended and auto-reprocess completed, the transcript showed all remote participant speech grouped together, then all local speech grouped together.
- Timestamps on blocks were correct individually, but the block ordering was wrong -- a 60-minute meeting would show "Them [0:00]" through "Them [59:00]", then "Me [0:00]" through "Me [59:00]".
- The live transcript during recording was correctly interleaved; only the reprocessed result was broken.
- Second-pass ASR finalization was unaffected (it had the sort).

## Root Cause Analysis

`TranscriptionService.transcribePostProcessing()` processes audio sources sequentially:

1. First, all system audio chunks (speaker: `.them`) -- timestamps 0s through end
2. Then, all mic audio chunks (speaker: `.me`) -- timestamps 0s through end

This means segments arrive via the handler callback in two sequential batches, not interleaved by timestamp.

`runSecondPassASR()` correctly sorted segments by timestamp before feeding them to `TranscriptProcessor`. However, `reprocessTranscript()` fed segments in arrival order (unsorted), causing `TranscriptProcessor` to merge all `.them` segments into consecutive blocks, then all `.me` segments into consecutive blocks.

The bug affected all callers of `reprocessTranscript()`: auto-reprocess (default post-meeting path), manual reprocess from the UI, and bulk reprocess.

## Fix Description

Added `.sorted(by: { $0.timestamp < $1.timestamp })` to the segment processing loop in `reprocessTranscript()`, matching the pattern already used by `runSecondPassASR()`.

## Affected Files

- `Muesli/Managers/TranscriptionCoordinator.swift` - Added timestamp sort to `reprocessTranscript()` segment loop
- `MuesliTests/TranscriptProcessorTests.swift` - Added regression test

## Code Snippets

### Before

```swift
let processor = TranscriptProcessor()
for segment in segments {
    processor.processSegment(segment)
}
```

### After

```swift
let processor = TranscriptProcessor()
for segment in segments.sorted(by: { $0.timestamp < $1.timestamp }) {
    processor.processSegment(segment)
}
```

## Prevention/Testing

- Regression test added: `MuesliTests/TranscriptProcessorTests.swift` - `testReprocessTranscriptSortsSegmentsByTimestampBeforeProcessing()`
- Test validates both the bug (unsorted segments produce speaker-grouped blocks) and the fix (sorted segments produce chronologically interleaved blocks).

## Related Issues/PRs

- Related debug log: `2026-02-24_reprocessing-race-condition.md` (race condition between second-pass and auto-reprocess)

## Notes

- Swift's `sorted(by:)` is stable, so segments with identical timestamps preserve arrival order (`.them` before `.me`), matching `runSecondPassASR()` behavior.
- Pre-existing limitation discovered: `reprocessTranscript()` only processes `audio.caf` and `microphone.caf`, not segment-numbered files from resumed recordings. Tracked separately in `plans/todo.md`.
