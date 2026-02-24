# AEC convergence recovery: preserve filter through silence freezes

**Date**: 2026-02-24 10:15
**Category**: Echo Cancellation

## Problem Description

Acoustic echo cancellation converged normally in isolated tests, but during normal meetings the echo remained and microphone transcripts duplicated.
The AEC repeatedly entered a non-converging state after periods of render silence, especially around VAD pauses in meeting apps.

## Symptoms/Error Messages

Observed during the 9:29am meeting replay and diagnostics:

- `ERLE` stayed near `0.2dB` and failed to climb during speaking.
- `AEC_NONCONVERGING` events remained frequent in the timeline.
- Logs showed repeated freeze/reset/recovery patterns:
  - `AEC_FREEZE`
  - `AEC_RESET`
  - `AEC_UNFREEZE`
- Transcript cleanup in the mic stream still showed repeated loopback-like text during resumed speaking.

## Root Cause Analysis

- AEC adaptation was being reset in two uncoordinated paths on render-silence recovery:
  - `AECProcessor.updateGatingLocked()` reset the WebRTC bridge whenever unstable→stable transition was detected.
  - `AudioWorker` froze on render silence and then called `aecProcessor.reset()` when render resumed.
- This destroyed learned filter state and effectively restarted AEC adaptation during normal conversation gaps, creating a repeated convergence failure loop.
- The freeze threshold was too aggressive (`5s`) and triggered too often on VAD-influenced silence intervals.

## Fix Description

- Preserve learned AEC3 state when unfreezing after temporary instability:
  - Removed `state.bridge?.reset()` from `AECProcessor.updateGatingLocked()` and emit `AEC_GATING_PRESERVED`.
- Preserve learned AEC3 state on render-silence resume:
  - Removed `aecProcessor.reset()` from `AudioWorker` resume path and emit `AEC_RENDER_RESUME_PRESERVED`.
  - Kept `unfreezeAdaptation()` so state transitions remain explicit without clearing filter state.
- Raised the silence freeze threshold from 5s to 30s and clarified extended logging milestones (30s/60s).
- Added regression guards in tests to prevent reintroducing reset-on-resume behavior and to lock in the new thresholds.

## Affected Files

- `Muesli/Services/AECProcessor.swift` - removed destructive reset from stable transition handling and added preserved-state diagnostics.
- `Muesli/Services/AudioWorker.swift` - raised render silence threshold, removed resume reset, updated diagnostics/log wording, added test constants.
- `MuesliTests/RegressionTests.swift` - added coverage for preserved-state behavior, 30s/60s guardrails, and reset-requirement sanity checks.
- `docs/debug-logs/2026-02-24_aec_convergence_freeze_reset_fix.md` - root-cause + fix documentation.

## Code Snippets

### Before

```swift
// AECProcessor.updateGatingLocked(state:isStable:)
if !isStable {
    if !state.isAdaptationFrozen {
        state.isAdaptationFrozen = true
        state.stats.adaptationFrozen = true
    }
} else if state.isAdaptationFrozen {
    state.bridge?.reset()          // removed
    state.isAdaptationFrozen = false
    state.stats.adaptationFrozen = false
}
```

### After

```swift
if !isStable {
    if !state.isAdaptationFrozen {
        state.isAdaptationFrozen = true
        state.stats.adaptationFrozen = true
    }
} else if state.isAdaptationFrozen {
    // Preserve learned filter state across normal pauses.
    state.isAdaptationFrozen = false
    state.stats.adaptationFrozen = false
}
```

## Prevention/Testing

- Added regression tests in `MuesliTests/RegressionTests.swift`:
  - `testAECGatingUnfreezePreservesFilterState`
  - `testAECRenderSilenceResumePreservesFilterState`
  - `testRenderSilenceFreezeThreshold30s`
  - `testTopologyChangeStillResetsAEC`
- Planned verification after build/run:
  - sustained `ERLE > 2dB`
  - no `AEC_NONCONVERGING` for normal meeting-like audio
  - no transcript duplication/echo regression

## Notes

- Legitimate resets are kept in lifecycle boundaries (`TapAudioCaptureService`) such as session start/stop, mic switch, and route change where environment assumptions change.
