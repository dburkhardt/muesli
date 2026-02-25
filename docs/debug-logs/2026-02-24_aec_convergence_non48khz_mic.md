# AEC Convergence Failure with Non-48kHz Microphones

**Date**: 2026-02-24 07:45
**Category**: Echo Cancellation

## Problem Description

AEC (Acoustic Echo Cancellation) never converges when the microphone operates at a non-48kHz sample rate (e.g., Logitech C920 webcam at 44.1kHz). The synchronizer is permanently stuck in the `unstable` state, keeping AEC adaptation frozen for the entire recording session. This results in speaker audio leaking into the microphone transcript ("Me" blocks repeat what "Them" says) and fully duplicated transcription during post-processing.

## Symptoms/Error Messages

- Live transcription: "Me" blocks contain echo of the other speaker's words
- Post-processing: fully duplicated transcript (both audio streams produce identical text)
- Diagnostic logs show continuous capture discontinuities and AEC frozen:

```
[AEC] SYNC_DISCONTINUITY: source=capture, total=1, repeated=false, cooldownRefreshed=true
[AEC] SYNC_DISCONTINUITY: source=capture, total=2, repeated=true, cooldownRefreshed=false
... (80 events over 40 seconds)
[AEC] AEC_TELEMETRY: ERLE=0.2dB, delay=0ms, seededDelay=-1ms, stable=false, frozen=true
[AEC] MIC_SAMPLE_RATE: hardware=44100.0Hz, channels=2, tapOutput=44100.0Hz/2ch, aecTarget=48000Hz, resampler=true
```

Conditions:
- USB microphone at non-48kHz rate (C920 at 44.1kHz confirmed)
- Mic resampler active (`resampler=true` in logs)
- AEC enabled in speakerphone topology

## Root Cause Analysis

`handleMicrophoneBuffer` in `TapAudioCaptureService.swift` correctly resamples mic audio from 44.1kHz to 48kHz for the AEC pipeline, but passes the **original AVAudioTime sampleTime** (44.1kHz domain) alongside the **resampled sample count** (48kHz domain) to `synchronizer.pushCapture()`.

Inside `MicCaptureRing.push()`, discontinuity detection computes:
```
lastSampleTime = sampleTime + Float64(sampleCount)
```

This mixes domains. On the next callback:
- `sampleTime` advances by ~4096 (frames at 44.1kHz)
- `lastSampleTime` was `prevSampleTime + ~4458` (resampled count at 48kHz)
- `delta = 4096 - 4458 = -362`, below `negativeTolerance` of -240
- Discontinuity fires every callback (after the 5-callback debounce window)

The continuous discontinuities prevent `canTransitionToStable()` from ever returning true (requires 5 seconds without discontinuity), keeping AEC adaptation permanently frozen.

## Fix Description

1. **Primary fix**: When the mic resampler is active, pass the 48kHz-domain `startSampleIndex` (from `captureSampleIndexCounter`) as the `sampleTime` parameter instead of the source-domain AVAudioTime. Since `startSampleIndex` increments by `aecCount` each callback, the delta is always 0 — no false discontinuities.

2. **Secondary fix**: Replaced undefined `sampleArray` variable on line 1152 with properly constructed `rawMicSamples` from `floatChannelData[0]`. Made the allocation conditional on `saveRaw` to minimize heap churn on the audio callback thread.

3. **Actor-isolation fix**: Changed `deliverRawMicAudio` to accept a `sampleRate` parameter (from `buffer.format.sampleRate`) instead of reading the actor-isolated `microphoneSampleRate` property from within the `nonisolated` callback.

## Affected Files

- `Muesli/Services/TapAudioCaptureService.swift` - sampleTime domain fix in `handleMicrophoneBuffer`, `deliverRawMicAudio` signature change, diagnostic logging flag
- `MuesliTests/CoreAudioTapTests.swift` - Regression tests for domain mismatch

## Code Snippets

### Before

```swift
synchronizer.pushCapture(
    samples: aecSamples,
    count: aecCount,
    sampleTime: Float64(sampleTime),  // 44.1kHz domain!
    hostTime: hostTime
)
```

### After

```swift
let captureSampleTime: Float64 = (micResampler != nil)
    ? Float64(startSampleIndex)  // 48kHz domain (matches aecCount)
    : sampleTime                  // native domain (already matches count)

synchronizer.pushCapture(
    samples: aecSamples,
    count: aecCount,
    sampleTime: captureSampleTime,
    hostTime: hostTime
)
```

## Prevention/Testing

- Regression tests added:
  - `testMicCaptureRingDomainMismatchCausesFalseDiscontinuity()` — proves the old bug triggers discontinuity
  - `testMicCaptureRingFixedDomainNoFalseDiscontinuity()` — proves the fix prevents it
  - `testSynchronizerStabilizesWithResampledMicTimeDomain()` — integration test for synchronizer stability

## Related Issues/PRs

- Regression tests: `MuesliTests/CoreAudioTapTests.swift`
- Related debug log: `2026-02-17_mic-sample-rate-race.md` (earlier sample-rate related issue)

## Notes

- Affects any USB microphone with a non-48kHz native rate (not just C920)
- The `DriftTracker` in `AudioSynchronizer.pushCapture()` also receives the corrected sampleTime automatically
- Resampler error fallback (when `converter.convert` fails) has a pre-existing issue where native-rate frames are pushed to the 48kHz synchronizer — filed as follow-up
- `raw_microphone.caf` now uses the mic's native sample rate (e.g., 44.1kHz), not forced 48kHz — output contract in AGENTS.md should be updated
