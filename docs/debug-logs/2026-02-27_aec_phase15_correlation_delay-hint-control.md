# AEC Phase 1.5 Correlation and Delay-Hint Control

**Date**: 2026-02-27 17:35
**Category**: Echo Cancellation

## Problem Description

The AEC root-cause handoff identified remaining ambiguity between persistent delay mismatch signals and actual convergence quality. Existing diagnostics could show ERLE, delay mismatch warnings, and pass-through heuristics, but did not quantify second-by-second correlation between low ERLE windows and large delay deltas, nor provide decomposition of synchronizer delay terms in the same cadence.

The plan also required one least-invasive behavioral fix path with rollback guard once correlation evidence was in place.

## Symptoms/Error Messages

- Session quality varied even when bridge delay-set calls were accepted.
- `DELAY_MISMATCH_FAIL` appeared in both poor and better sessions, making it insufficient alone to drive a fix.
- Missing fixed-size 1 Hz correlation counters made it hard to determine causality.

Representative diagnostics after this change:

```
AEC_PHASE15: windowFrames=100, totalFrames=5600, erleBelow3Pct=84.0, deltaOver100Pct=91.0, coincidencePct=81.0, regime=far_end_dominant, collapseSeconds=16, collapseAlert=true, ...
AEC_PHASE15_CSV: windowFrames=100,totalFrames=5600,erleBelow3Frames=84,deltaOver100Frames=91,coincidentFrames=81,...
AEC_DELAY_HINT_CONTROL_CONFIG: enabled=true, slewLimitMsPerFrame=8, diagnosticsVerbose=true
```

## Root Cause Analysis

- The system lacked a direct 1 Hz correlation summary tying three signals together:
  1. low ERLE (`ERLE < 3 dB`),
  2. large delay divergence (`|bridge-sync| > 100 ms`),
  3. overlap/coincidence of both conditions.
- Delay decomposition values (`seeded`, `coarse`, drift-derived adjustment) were not emitted in the same machine-readable record as ERLE/delta correlations.
- Delay hints could jump abruptly frame-to-frame during unstable windows; this was a plausible destabilizer and the least invasive fix candidate to gate behind a runtime toggle.

## Fix Description

### 1) Phase 1.5 fixed-size correlation counters (worker-owned)

- Added preallocated, fixed-size counters in `AECProcessor` for:
  - total frames
  - ERLE-below-threshold frames
  - delta-over-threshold frames
  - coincident frames
  - fixed histogram bins for delta ranges
- Added `recordPhase15Sample(syncDelayMs:)` that emits a summary once per 100 frames (1 second).

### 2) Delay decomposition snapshot

- Added worker-safe `delayDecompositionSnapshot()` in `AudioSynchronizer` returning:
  - `seededDelayMs`
  - `coarseDelayMs`
  - `driftPPM`
  - `driftAdjustmentMsPerSec`
  - `effectiveCoarseDelayMs`
  - `sourceTag` (`unavailable`, `seededOnly`, `coarseOnly`, `coarseAndSeeded`)

### 3) Least-invasive behavioral fix path (feature-flagged)

- Implemented delay-hint control in `AudioWorker`:
  - hold last hint during unstable windows
  - apply slew limit (default 8 ms/frame) to large jumps in stable windows
- Runtime gate:
  - `aecDelayHintControlEnabled` (default `true`)
- Rollback:
  - disable by setting `UserDefaults` key `aecDelayHintControlEnabled=false` and relaunch.

### 4) Machine-readable summary and collapse detector

- Added `AEC_PHASE15` and `AEC_PHASE15_CSV` logs at 1 Hz with:
  - ERLE/delta coincidence percentages
  - decomposition terms and slope
  - delay-hint clamp/hold counters
  - regime labels and collapse-seconds tracking

## Affected Files

- `Muesli/Services/AECProcessor.swift` - phase 1.5 fixed-size counters, 1 Hz summaries, debug hooks
- `Muesli/Services/AudioSynchronizer.swift` - delay decomposition snapshot and source-tag mapping
- `Muesli/Services/AudioWorker.swift` - correlation emission, regime/collapse detector, delay-hint control + runtime flag
- `MuesliTests/CoreAudioTapTests.swift` - delay-hint control behavior tests
- `MuesliTests/RegressionTests.swift` - phase 1.5 counter/decomposition deterministic tests

## Code Snippets

### Before

```swift
// No 1 Hz ERLE-vs-delay coincidence counters were available.
// Delay telemetry existed, but not explicit fixed-size correlation windows.
```

### After

```swift
if let phaseSummary = aecProcessor.recordPhase15Sample(syncDelayMs: syncCoarseDelayMs) {
    let delayDecomposition = synchronizer.delayDecompositionSnapshot()
    emitPhase15Summary(summary: phaseSummary, delayDecomposition: delayDecomposition)
}
```

## Prevention/Testing

- Added deterministic tests:
  - `testPhase15SummaryEmitsAtOneSecondWindowAndResets`
  - `testPhase15ThresholdBoundariesAreExclusive`
  - `testDelayDecompositionSourceTagMapping`
  - `testAudioWorkerDelayHintControlHoldsHintDuringUnstableWindows`
  - `testAudioWorkerDelayHintControlSlewLimitsLargeStableJump`

- Targeted test run succeeded:
  - 5 selected tests, 0 failures.

- Broader focused suite (`RegressionTests` + `CoreAudioTapTests`) currently includes one unrelated pre-existing failure:
  - `testStartMicrophoneCaptureWrapsInstallTapCallsInObjCTryCatch`
  - This failure was not introduced by the phase 1.5 changes.

## Related Issues/PRs

- Regression tests:
  - `MuesliTests/RegressionTests.swift`
  - `MuesliTests/CoreAudioTapTests.swift`
- Related debug logs:
  - `docs/debug-logs/2026-02-24_aec_convergence_non48khz_mic.md`
  - `docs/debug-logs/2026-02-25_stop-ui-hang-and-aec-delay-hint-regression.md`

## Notes

- Real-capture validation matrix from the plan (08:06-like topology + additional meeting runs) remains required for final sign-off and should be executed on-device with live audio.
- This change intentionally keeps fix scope narrow: hint conditioning only, no broad AEC pipeline refactor.
- Rollback procedure:
  1. Set `UserDefaults.standard.set(false, forKey: "aecDelayHintControlEnabled")`
  2. Relaunch app
  3. Compare `AEC_PHASE15`/ERLE behavior with flag off vs on

## Follow-up Corrections (edc5af3)

### 1) Bridge-unavailable gating in Phase 1.5

- `recordPhase15Sample(syncDelayMs:)` now uses an explicit invalid sentinel for bridge delay (`-1`) when bridge is unavailable/not ready.
- Invalid-delay samples are excluded from delta threshold, coincidence, and histogram bin counting.
- Added `invalidDelaySamples` in `AEC_PHASE15` / `AEC_PHASE15_CSV` for observability of startup or bridge-unready windows.

### 2) Cadence-safe render RMS policy

- Canonical policy: when no render frame is consumed in a worker iteration, Phase 1.5 render RMS uses zero-fill for capture-frame aligned accumulation.
- This prevents stale carry-forward from prior render iterations from biasing regime classification and collapse streak detection.

### 3) Delay-hint source attribution (`requested` vs `applied`)

- Unstable-window hold now preserves both the previous applied delay value and previous applied source.
- `streamDelaySource` reflects the source that actually produced the applied hint, not the newly requested source during hold.
- Startup edge behavior is explicit: if no valid hint has been applied yet, source remains `.unknown`.
