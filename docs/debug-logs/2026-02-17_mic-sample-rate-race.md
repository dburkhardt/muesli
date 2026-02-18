# Microphone Sample Rate Race Condition (Sped-Up Playback)

**Date**: 2026-02-17
**Category**: Audio

## Problem Description

The `microphone.caf` file played back sped up because of a race condition between two initialization paths in `TapAudioCaptureService`. A cached `micFormatDesc` was overwritten with the wrong sample rate (48kHz) even when the actual hardware mic operated at a different rate (e.g., 44100Hz).

## Symptoms/Error Messages

- `microphone.caf` plays back faster than normal (sped-up audio)
- No error messages in logs — the bug is silent
- Affects any microphone not running at exactly 48kHz (USB mics at 44100Hz, Bluetooth at 16kHz, etc.)

## Root Cause Analysis

Race condition between two initialization paths in `TapAudioCaptureService`:

1. `startMicrophoneCapture()` correctly detects the hardware mic rate (e.g., 44100Hz) and updates `micFormatDesc`
2. `ensureFormatDescriptionsInitialized()` — called lazily on the first audio buffer — runs `setupFormatDescriptions()` which **unconditionally overwrites `micFormatDesc` back to 48kHz**
3. The downstream `RecordingController` reads 48kHz from the format description, skips resampling, and writes 44100Hz data into a 48kHz CAF file

The ordering depended on which path ran first. If `ensureFormatDescriptionsInitialized()` ran after `startMicrophoneCapture()`, it would overwrite the correct rate. If it ran before, the subsequent update in `startMicrophoneCapture()` would be correct — but only until the next lazy init call.

Previous fixes targeted symptoms (resampling logic, file writer settings) rather than the structural root cause: shared mutable state (`micFormatDesc`).

## Fix Description

**Structural fix**: Removed the cached `micFormatDesc` entirely, eliminating the race condition.

1. **Deleted** the `micFormatDesc` property
2. **Deleted** mic format description creation from `setupFormatDescriptions()` (kept only system audio format desc)
3. **Deleted** the conditional update block in `startMicrophoneCapture()` (no longer needed)
4. **Changed** `deliverRawMicAudio()` to pass `nil` for `formatDesc` parameter — this makes `createCMSampleBuffer()` create a fresh format description per-buffer using the actual `microphoneSampleRate`
5. **Added** once-per-session diagnostic log for mic sample rate
6. **Added** once-per-session debug log in `RecordingController` for non-48kHz mic rates

The per-buffer format description creation uses the existing `nil` codepath in `createCMSampleBuffer()`, which builds a `CMFormatDescription` from the `sampleRate` parameter. `CMAudioFormatDescriptionCreate` is lightweight (ASBD struct copy + refcount), and the system audio path already creates format descs per-buffer without issue.

Thread safety note: `microphoneSampleRate` is actor-isolated (TapAudioCaptureService is an actor). The nonisolated `handleMicrophoneBuffer` callback dispatches to `deliverRawMicAudio` via `Task { await self?.deliverRawMicAudio(...) }`, which runs on the actor.

## Affected Files

- `Muesli/Services/TapAudioCaptureService.swift` - Removed `micFormatDesc` property; removed mic desc from `setupFormatDescriptions()`; removed conditional update in `startMicrophoneCapture()`; pass `nil` formatDesc in `deliverRawMicAudio()`; added diagnostic log
- `Muesli/Controllers/RecordingController.swift` - Added `micRateLoggedLock`; added once-per-session debug log for non-48kHz mic rate
- `MuesliTests/RegressionTests.swift` - Added regression tests for 44100Hz, 16kHz, 32kHz, 48kHz mic → 48kHz file output

## Code Snippets

### Before (TapAudioCaptureService — race-prone cached state)

```swift
// Property
private var micFormatDesc: CMFormatDescription?

// setupFormatDescriptions() — unconditionally creates 48kHz mic desc
var micASBD = AudioStreamBasicDescription(mSampleRate: 48000, ...)
CMAudioFormatDescriptionCreate(..., formatDescriptionOut: &micFormatDesc)

// startMicrophoneCapture() — tries to fix it, but may lose the race
if tapSampleRate != 48000 {
    var micASBD = AudioStreamBasicDescription(mSampleRate: tapSampleRate, ...)
    CMAudioFormatDescriptionCreate(..., formatDescriptionOut: &micFormatDesc)
}

// deliverRawMicAudio() — uses potentially stale cached desc
createCMSampleBuffer(..., formatDesc: micFormatDesc)
```

### After (no cached mic format desc — race eliminated)

```swift
// Property: REMOVED

// setupFormatDescriptions() — only creates system audio format desc
// Note: Mic format description is NOT pre-allocated here.

// startMicrophoneCapture() — just records the rate, no format desc update needed
microphoneSampleRate = tapSampleRate

// deliverRawMicAudio() — creates fresh desc from actual rate every time
createCMSampleBuffer(..., formatDesc: nil)  // creates from microphoneSampleRate
```

## Prevention/Testing

- **Regression tests added**: `MuesliTests/RegressionTests.swift`
  - `testNon48kHzMicResampledTo48kHzForFileOutput()` — 44100Hz → 48kHz
  - `testBluetooth16kHzMicResampledTo48kHz()` — 16kHz → 48kHz
  - `testExotic32kHzMicResampledTo48kHz()` — 32kHz → 48kHz
  - `testNative48kHzMicPassesThrough()` — 48kHz → 48kHz (no-op)
- **Diagnostic logging**: `MIC_SAMPLE_RATE` in diagnostic log, plus `[MIC DEBUG]` print for non-48kHz rates
- **Architecture changed**: Eliminated shared mutable state that caused the race

## Notes

- The fix removes the possibility of the race rather than trying to win it (structural > temporal)
- If profiling shows per-buffer `CMAudioFormatDescriptionCreate` is a bottleneck, the safe optimization is a session-scoped cache keyed on `microphoneSampleRate` — but this is premature now
- The `formatDescriptionsInitialized` guard and `ensureFormatDescriptionsInitialized()` still work cleanly — they now only initialize the system audio format desc
