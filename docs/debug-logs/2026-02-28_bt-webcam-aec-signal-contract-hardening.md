# Bluetooth + Webcam AEC Signal Contract Hardening

**Date**: 2026-02-28 17:10
**Category**: Echo Cancellation

## Problem Description

Bluetooth speaker + external webcam microphone AEC was unstable across multiple sessions. The route that worked on built-in audio failed on BT + webcam due to microphone capture integrity regressions and AEC non-convergence.

## Symptoms/Error Messages

- BT + webcam sessions showed persistent poor cancellation (`AEC_NONCONVERGING`, low ERLE).
- Multiple sessions produced missing or silent microphone output (`captureFrames=0`, `micBytes=0`, `captureRms=-96.0dBFS`).
- After HAL-first migration, converter failures appeared with mismatched contract telemetry.

```
Session 813C5433:
- MIC_CAPTURE_BACKEND: backend=hal
- MIC_SAMPLE_RATE: hardware=16000.0Hz, channels=2
- MIC_RESAMPLER_SUMMARY ... statusError=32, sourceSampleRate=16000.0
- convertStatus=error (repeated)
```

## Root Cause Analysis

Two stacked failures were interacting:

1. Signal-integrity regression in microphone conversion path:
   - HAL callback delivered mono channel-zero data.
   - Converter source format did not consistently follow delivered channel shape.
   - Converter failure path allowed unsafe non-contract behavior.

2. AEC adaptation instability on BT + external mic:
   - Delay/startup behavior and non-convergence heuristics were being evaluated while the capture path was not reliably contract-clean.

## Fix Description

Implemented staged hardening around a strict microphone signal contract, then retuned AEC diagnostics:

- Added explicit signal-contract telemetry (`MIC_SIGNAL_CONTRACT`) with backend, source/nominal rates, hardware channels, delivery channels, converter channels, and validity.
- Enforced converter alignment to callback delivery shape (HAL delivery is mono channel-zero -> converter source channels set to 1).
- Replaced raw passthrough on converter failure with deterministic zero-fill in 48k timing domain.
- Added converter escalation policy:
  - `>= 10` consecutive converter failures -> mic recovery restart.
  - `>= 3` recoveries in 60s -> force AVAudioEngine fallback for the session.
  - if fallback still fails contract -> disable AEC mic path and emit degraded warning.
- Revalidated route/liveness recovery paths with post-restart contract validation.
- Tuned AEC diagnostics to avoid low-energy false positives:
  - pass-through BT recovery counters now require healthy render/capture energy.
  - `AEC_NONCONVERGING` now requires both render and capture signal energy.

## Affected Files

- `Muesli/Services/TapAudioCaptureService.swift` - signal contract state, converter policy, fallback/degraded behavior, telemetry, and recovery validation.
- `Muesli/Utilities/CoreAudioHelpers.swift` - nominal sample-rate and format snapshot helpers for contract telemetry.
- `Muesli/Services/AudioWorker.swift` - low-energy gating for BT pass-through/non-converging recovery metrics.
- `Muesli/Services/AECProcessor.swift` - non-converging detection tightened to require two-sided signal energy.
- `MuesliTests/CoreAudioTapTests.swift` - added contract/evaluation/escalation regression tests.
- `MuesliTests/RegressionTests.swift` - added regression coverage for contract mismatch and escalation policy.
- `AGENTS.md` - architecture text updated to HAL-first mic backend + fallback.
- `SPEC.md` - architecture/status docs updated for HAL-first mic backend.
- `spec/audio_pipeline.md` - signal contract and converter failure policy documented.

## Code Snippets

### Before

```swift
if let e = error {
    converterError = e.localizedDescription
    // Fallback: use raw channel 0
    aecSamples = floatChannelData[0]
    aecCount = frameLength
}
```

### After

```swift
let hasUsableOutput = (status == .haveData || status == .inputRanDry)
    && error == nil
    && outBuf.frameLength > 0
if hasUsableOutput, let outData = outBuf.floatChannelData?[0] {
    aecSamples = outData
    aecCount = Int(outBuf.frameLength)
} else {
    // Preserve AEC cadence and 48k contract on failure.
    let zeroPtr = UnsafeMutablePointer<Float>.allocate(capacity: expectedFrameCount)
    zeroPtr.initialize(repeating: 0, count: expectedFrameCount)
    aecSamples = zeroPtr
    aecCount = expectedFrameCount
}
```

## Stage-Gated Hardware Validation Matrix

### Gate A: Signal Integrity (must pass first)

- Route: Bluetooth speaker + C920 webcam mic
- Required log conditions:
  - `MIC_CAPTURE_BACKEND=hal` unless explicit fallback policy activation
  - `MIC_SIGNAL_CONTRACT` reports `contractValid=true`
  - converter source channels == delivery channels
  - converter output rate == 48000
  - no sustained converter `statusError` bursts
  - no `micBytes=0` during active speech
  - no sustained `captureRms=-96.0dBFS` with speech present

### Gate B: AEC Performance (only after Gate A)

- Required log conditions:
  - no sustained `AEC_NONCONVERGING`
  - no sustained `DELAY_MISMATCH_FAIL`
  - `AEC_PASS_THROUGH_AUDIT` attenuation improved over prior failing baseline
  - ERLE quality target: median improvement >= +6 dB vs baseline failing sessions

### Scenarios

- Built-in speaker + built-in mic (control)
- Bluetooth speaker + C920 webcam mic (primary)
- BT headset same-device I/O (sanity)
- Route churn mid-session (connect/disconnect)

## Release Readiness / Rollback Guardrails

Go/no-go before production:

- Signal contract gate passed on primary hardware scenario.
- AEC gate passed on primary scenario with no regressions on built-in route.
- Regression tests for contract/escalation are green.
- Build includes telemetry (`MIC_SIGNAL_CONTRACT`, converter summary) for field triage.

Rollback triggers:

- repeated converter escalation entering degraded AEC mode in normal user scenarios.
- any reappearance of contract mismatch or sample-rate domain leakage in logs.
- built-in route regression in cancellation quality or capture availability.

Rollback mechanism:

- revert to pre-change commit set for microphone contract hardening.
- restore previous backend policy while preserving diagnostic logs for triage.

## Prevention/Testing

- Added deterministic pure-function tests for:
  - signal contract evaluation
  - converter recovery escalation
  - zero-fill frame count behavior
- Documented HAL-first contract invariants in architecture docs.
- Added explicit telemetry to make contract violations observable before AEC tuning decisions.

## Related Issues/PRs

- Regression tests: `MuesliTests/CoreAudioTapTests.swift`
- Regression tests: `MuesliTests/RegressionTests.swift`
- Related debug log: `2026-02-24_aec_convergence_non48khz_mic.md`

## Notes

- This fix intentionally prioritizes signal integrity over aggressive AEC retuning.
- If hardware validation exposes new BT-specific delay behavior, tune AEC only after contract telemetry stays clean.
