# Issue #41 AEC Delay Hint Stabilization

**Date**: 2026-02-26 11:13
**Category**: Echo Cancellation

## Problem Description

AEC delayed mismatch and non-convergence persisted in speakerphone scenarios after earlier delay-hint rewrites. The remaining failure mode was a timing-identity mismatch between observed delay intent and what the bridged AEC instance could actually apply, combined with a partially supported delay estimator path in the bundled WebRTC v2.x artifact.

## Symptoms/Error Messages

- `DELAY_MISMATCH_WARN` and `DELAY_MISMATCH_FAIL` patterns were still possible to diagnose but not consistently actionable.
- Logs showed `AEC_TELEMETRY` and `DELAY_AUDIT` without explicit evidence of whether `setStreamDelayMs` was truly effective.
- Some paths still reported stream hint values even when WebRTC could not consume them.
- Existing AEC convergence work was still impacted by non-48kHz capture timing edge cases in other components.

Representative logs observed after the stabilization changes:

```
session=... AEC_TELEMETRY: ERLE=-...
, delay=...
, streamDelayRaw=140ms, streamDelay= -1ms, streamDelaySource=coarse
, externalDelayEstimator=false, ...
session=... DELAY_AUDIT: streamDelayMs=-1, streamDelaySource=coarse, bridgeDelayMs=..., synchronizerDelayMs=...
```

## Root Cause Analysis

- `WebRTCAECBridge` reported `externalDelayEstimator` support as unavailable in the v2.x bundle, but previous runtime checks and docs were still treating delay hinting as potentially effective.
- Delay-hint telemetry lacked sufficient fields to distinguish raw intent from applied bridge value.
- Two-tier sustained mismatch thresholds were present, but acceptance logic did not explicitly separate no-op hinting from active hinting in all test paths.

## Fix Description

1. Explicit runtime contract for delay hints:
   - In `AECProcessor.setStreamDelayMs`, raw hint and source are still captured for observability.
   - Applied `streamDelay` is only committed when `externalDelayEstimatorEnabled` is true.
   - In active no-op mode, `streamDelay` remains `-1` while raw/source telemetry remains visible.
2. Kept deterministic selection semantics in `AudioWorker`:
   - `coarseDelayMs > 0` takes precedence over seeded fallback.
   - Fallback seeded delay only when coarse is unavailable.
3. Reworked telemetry to make hint effectiveness explicit:
   - `AEC_TELEMETRY` now includes `streamDelayRaw`, `streamDelay`, and `streamDelaySource`.
   - `DELAY_AUDIT` now includes bridge/synchronizer deltas in the same timestamp.
4. Strengthened delay mismatch guardrails:
   - Deterministic `DELAY_MISMATCH_WARN` / `DELAY_MISMATCH_FAIL` thresholds with sustained-frame durations.
   - Reset events now emit `DELAY_MISMATCH_CLEARED` once healthy alignment returns.
5. Regression coverage:
   - Added deterministic tests in `CoreAudioTapTests.swift` and `RegressionTests.swift` for hint precedence, clamping boundaries, and mismatch policy.
   - Added estimator path mapping test (`testSetStreamDelayMsPathAorBEstimatorBehavior`) that validates applied vs no-op behavior by contract.

## Affected Files

- `Muesli/Services/WebRTCAEC/WebRTCAECBridge.mm` - corrected artifact-level estimator support contract
- `Muesli/Services/AECProcessor.swift` - applied stream delay now commits only when estimator path is active
- `MuesliTests/RegressionTests.swift` - updated estimator path tests and clamped-delay expectations
- `Muesli/Services/AudioWorker.swift` - deterministic hint source selection (`coarse` over `seeded`)
- `spec/AEC_architecture.md` - documented runtime behavior, hint contract, and mismatch contract

## Prevention/Testing

- Unit tests:
  - `MuesliTests/CoreAudioTapTests.swift`
    - `testAudioWorkerUsesCoarseDelayWhenAvailable`
    - `testAudioWorkerFallsBackToSeededDelayWhenCoarseZero`
    - `testAudioWorkerDelayHintSelectsNoneWhenUnavailable`
  - `MuesliTests/RegressionTests.swift`
    - `testSetStreamDelayMsRecordedInStats`
    - `testSetStreamDelayMsRecordsRawValueAndSource`
    - `testSetStreamDelayMsClampedToRange0to500`
    - `testSetStreamDelayMsPathAorBEstimatorBehavior`
    - `testDelayMismatchWarnBoundary_20ms3s`
    - `testDelayMismatchFailBoundary_80ms5s`
    - `testDelayMismatchClearsResetsSustainedCounter`
    - `testDelayMismatchSuppressedWhenRmsTooLow`
- Runtime matrix still requires manual captures on target hardware as a follow-up acceptance check.

## Related Issues/PRs

- Plan item: `.cursor/plans/issue_41_aec_stabilization_e08ca722.plan.md`
- Architecture reference: `spec/AEC_architecture.md`
- Runtime logs: `docs/debug-logs/README.md`

## Notes

- This is a rollback-safe change:
  - If convergence regresses after deployment, reverse the `externalDelayEstimatorEnabled=false` and no-op gating path in `AECProcessor.setStreamDelayMs` / `WebRTCAECBridge.mm`.
  - Keep telemetry and tests in place to confirm whether `streamDelay` is ever applied after rollback.
- Remaining explicit acceptance item is manual run matrix with 3 real captures (including 44.1kHz mic) to confirm steady ERLE convergence behavior.
