# Stop Finalization UX Restoration After Revert

**Date**: 2026-02-26 10:05
**Category**: Recording

## Problem Description

Issue #40 resurfaced after revert commit `1fe2214` removed stop-flow UX logic that had previously made post-stop finalization states explicit and responsive.

## Symptoms/Error Messages

- Stop could feel stalled before UI clearly showed background finalization/reprocessing.
- Processing indicator text was generic (`Reprocessing...`) and did not surface a distinct live-finalization phase.
- Regression tests around stop-flow source patterns failed after restoring behavior because assertions were tied to older code shape.

## Root Cause Analysis

- `1fe2214` removed:
  - bounded/deferred transcription flush controls in stop flow,
  - `finalizingLive` processing phase metadata,
  - UI status-text override path in `FloatingProcessingIndicator`.
- This regressed user-facing stop transition clarity and removed phase-specific indicator language.

## Fix Description

- Reintroduced bounded stop flush API (`maxFlushDuration` + `allowDeferredFlush`) in `TranscriptionService` and protocol surface.
- Restored stop-flow timing + deferred flush orchestration in `RecordingController` for live+second-pass.
- Restored `finalizingLive` processing state in `TranscriptionCoordinator`.
- Restored per-state status text rendering in processing indicators.
- Updated mock/protocol/test scaffolding and adjusted brittle source-based regression assertions to current implementation shape.

## Affected Files

- `Muesli/Protocols/ServiceProtocols.swift` - Re-added parameterized stop API contract and compatibility overload.
- `Muesli/Services/TranscriptionService.swift` - Re-added `StopFlushResult`, bounded/deferred flush, and final flush helpers.
- `Muesli/Managers/TranscriptionCoordinator.swift` - Re-added `finalizingLive` phase/display status and stop API forwarding.
- `Muesli/Controllers/RecordingController.swift` - Restored stop timing diagnostics, deferred flush invocation, and `finalizingLive` lifecycle.
- `Muesli/Views/Components/RecordingIndicator.swift` - Restored optional status text override.
- `Muesli/Views/RecordingDetailView.swift` - Passes processing state display text to floating indicator.
- `Muesli/Views/CompletedMeetingWindow.swift` - Passes processing state display text to floating indicator.
- `MuesliTests/Mocks/MockTranscriptionService.swift` - Updated mock stop API + tracking fields.
- `MuesliTests/TranscriptionCoordinatorTests.swift` - Added tests for `finalizingLive` status and flush-budget forwarding.
- `MuesliTests/RegressionTests.swift` - Added/updated regression assertions for stop-flow deferred flush and finalizing phase.

## Code Snippets

### Before

```swift
await transcriptionCoordinator.stopTranscription()
```

### After

```swift
let flushResult = await transcriptionCoordinator.stopTranscription(
    maxFlushDuration: shouldUseDeferredFlush ? 1.5 : nil,
    allowDeferredFlush: shouldUseDeferredFlush
)
```

## Prevention/Testing

- Added/updated regression checks:
  - `testStopRecordingUsesDeferredFlushBudgetForSecondPass`
  - `testStopFlowUsesFinalizingLiveProcessingPhase`
  - `testFinalizingLiveProcessingStateHasExpectedStatusText`
  - `testStopTranscriptionForwardsFlushBudget`
- Verification run:
  - `xcodebuild -project Muesli.xcodeproj -scheme Muesli -destination 'platform=macOS' -only-testing:MuesliTests/TranscriptionCoordinatorTests -only-testing:MuesliTests/RegressionTests test`
  - Result: **TEST SUCCEEDED** (114 tests, 0 failures).

## Related Issues/PRs

- Related GitHub issue: #40
- Related debug log: `2026-02-25_second-pass-finalization-stopflow-latency.md`
- Related debug log: `2026-02-25_reprocessing-ui-stuck-stale-selection.md`
- Related debug log: `2026-02-25_stop-ui-hang-and-aec-delay-hint-regression.md`

## Notes

- The fix intentionally excludes AEC and ASR algorithmic changes from `0442137`; scope is stop/finalization UX and indicator lifecycle only.
