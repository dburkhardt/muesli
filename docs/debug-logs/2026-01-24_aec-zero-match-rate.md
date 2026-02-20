# AEC Zero Match Rate Bug Investigation

**Date**: 2026-01-24  
**Status**: In Progress  
**Category**: Audio / Echo Cancellation  
**Severity**: High (AEC completely non-functional)

## Problem Description

After implementing the improved AEC architecture with sample-count-based synchronization, echo cancellation is completely non-functional. The diagnostic logs show:

1. Streams synchronize successfully after ~1 second
2. Delivery offset is calculated and logged
3. But match rate remains at **0%** - no reference audio is ever found

### Symptoms

- Microphone signal meter moves (microphone capture working)
- System audio is captured and saved correctly
- `MATCH: 0/100 (0.0%)`, `MATCH: 0/200 (0.0%)` etc. in logs
- No echo cancellation occurs (mic audio passes through unchanged)

### Diagnostic Log Evidence

```
[2026-01-24 12:55:08.667] [AEC] SYNC_WARNING: offset -24013 samples (-500.3ms) exceeds ±500ms, clamping
[2026-01-24 12:55:08.668] [AEC] SYNC_OFFSET: delivery_offset=-24000 samples (-500.3ms), mic_behind, sync_after=1.164s
[2026-01-24 12:55:18.566] [AEC] MATCH: 0/100 (0.0%)
[2026-01-24 12:55:28.573] [AEC] MATCH: 0/200 (0.0%)
```

Key observations:
- Offset was clamped from -24013 to -24000 (±500ms limit)
- Mic is ~500ms behind system audio (system audio arrives first)
- Sync completes after 1.164 seconds
- But still 0% match rate after sync

---

## Research and Analysis

### Code Flow Overview

1. **System Audio Path** (`storeSystemAudio`):
   - Counts samples immediately: `totalSystemSamples += samples.count`
   - Stores buffers with indices: `IndexedBuffer(samples, startSampleIndex: totalSystemSamples)`
   - Always buffers, even during warmup

2. **Microphone Audio Path** (`processMicrophoneAudio`):
   - Originally: counted samples AFTER sync guard (bug!)
   - Fixed: now counts samples BEFORE sync guard
   - Calculates `targetSysIndex = micStartIndex - acousticDelaySamples - deliveryOffsetSamples`
   - Looks up system audio at `targetSysIndex`

3. **Synchronization** (`checkAndSynchronizeStreams`):
   - Waits for `kBuffersToAverage` buffers from both streams
   - Calculates delivery offset from wall-clock arrival times
   - Sets `streamsSynchronized = true` after offset is calculated

### Hypotheses

#### Hypothesis 1: Sample Count Mismatch During Warmup (PARTIALLY FIXED)

**Original Issue**: Mic samples weren't counted during warmup, so after sync `totalMicSamples = 0` while `totalSystemSamples` was already large.

**Fix Applied**: Moved mic sample counting before the sync guard.

**Remaining Concern**: Even with this fix, the sample counts may still be misaligned because:
- System audio starts buffering with index 0 from the moment recording begins
- Mic audio also starts counting from 0
- But if mic starts 500ms later, mic index 0 corresponds to system index ~24000
- The delivery offset should compensate, but the sign/application may be wrong

#### Hypothesis 2: Index Calculation Sign Error (LIKELY)

The target index calculation:
```swift
let targetSysIndex = micStartIndex - Int64(acousticDelaySamples) - state.deliveryOffsetSamples
```

With `deliveryOffsetSamples = -24000` (mic behind, system first):
```
targetSysIndex = micStartIndex - 2400 - (-24000)
targetSysIndex = micStartIndex - 2400 + 24000
targetSysIndex = micStartIndex + 21600
```

This looks **forward** in the system buffer. But wait - let's trace through:

- At T=0: System starts, system index 0
- At T=500ms: Mic starts, mic index 0, but system is now at index 24000
- When processing mic index 0, we want system audio from T=500ms = system index ~24000
- So `micStartIndex + 21600 = 0 + 21600 = 21600` seems plausible

But after warmup (~1 second), both counters are much larger:
- totalSystemSamples ≈ 48000+ (1 second)
- totalMicSamples ≈ 48000+ (also counting during warmup now)

The issue is: **both counters start from 0 at recording start, not from their stream start times**. So:
- System: counts from 0 continuously
- Mic: counts from 0 continuously
- After 1 second warmup with mic 500ms behind:
  - System might have 48000 samples
  - Mic might have 24000 samples (started 500ms later)

Wait, but with my fix, mic now counts during warmup even though it returns early. So:
- If mic starts 500ms after system, mic's first buffer arrives at T=500ms
- But we start counting immediately when the buffer arrives
- So after warmup: `totalMicSamples ≈ totalSystemSamples - 24000`

Then: `targetSysIndex = micStartIndex - 2400 + 24000`

If `micStartIndex = 24000` (first buffer after sync):
`targetSysIndex = 24000 - 2400 + 24000 = 45600`

And `totalSystemSamples ≈ 48000`, so system buffers span ~0-48000.
`targetSysIndex = 45600` should be IN the buffer range!

Unless... the buffers are being pruned?

#### Hypothesis 3: Buffer Pruning Issue

```swift
if state.systemAudioBuffers.count > maxBuffers {
    state.systemAudioBuffers.removeFirst()
}
```

With `maxBuffers = 50` and buffer size ~4096:
- Max samples retained: 50 * 4096 = 204,800 samples (~4.3 seconds)
- This should be sufficient

But if the first buffers (indices 0-N) are pruned before sync completes, and the calculated `targetSysIndex` points to those pruned buffers, we'd get no match.

#### Hypothesis 4: kBuffersToAverage Was Too High (FIXED)

**Original**: `kBuffersToAverage = 50` (~4.25 seconds)
**Fixed**: `kBuffersToAverage = 12` (~1 second)

This was causing sync to happen very close to the 5-second timeout.

#### Hypothesis 5: Buffer Index Continuity Issue

The `findMatchingSystemAudioImpl` function requires buffers to be contiguous:
```swift
if nextBuffer.startSampleIndex == accumulatedEndIndex {
    // OK - buffers are contiguous
} else {
    // Gap in buffers - stop
}
```

If buffers aren't perfectly contiguous (e.g., due to timing jitter), lookups might fail.

---

## Instrumentation Added

Added diagnostic logging (not yet tested):

1. **INDEX log**: Shows mic index, acoustic delay, delivery offset, calculated target, and total system samples
2. **LOOKUP log**: Shows target index vs buffer range (min-max indices available)

These will help identify whether:
- The calculated target index is reasonable
- The target index falls within the available buffer range
- There are gaps in the buffers

---

## Debugging Plan

### Step 1: Verify Index Calculation

Run the build with new diagnostics and analyze:
- Is `targetSysIndex` within the buffer range?
- Is the offset sign correct?
- Are the sample counts reasonable after sync?

### Step 2: Test Sign Inversion

If `targetSysIndex` is outside buffer range, try inverting the offset sign:
```swift
// Current:
let targetSysIndex = micStartIndex - acousticDelaySamples - deliveryOffsetSamples

// Alternative:
let targetSysIndex = micStartIndex - acousticDelaySamples + deliveryOffsetSamples
```

### Step 3: Verify Buffer Retention

Check if buffers are being pruned too aggressively:
- Increase `maxBuffers` temporarily
- Log buffer count at sync time
- Log when buffers are pruned

### Step 4: Alternative Approach - Reset Counters at Sync

Consider resetting both counters when streams synchronize:
```swift
state.totalSystemSamples = 0
state.totalMicSamples = 0
state.systemAudioBuffers.removeAll()
```

This would give a clean slate after sync, but requires keeping enough pre-sync audio.

### Step 5: Simplify for Testing

Temporarily remove acoustic delay to simplify:
```swift
let targetSysIndex = micStartIndex - state.deliveryOffsetSamples
```

This removes one variable from the equation.

---

## Files Involved

- `Muesli/Services/EchoCancellationService.swift` - Main AEC logic
- `Muesli/Controllers/RecordingController.swift` - Calls AEC service
- `Muesli/Services/AudioCaptureService.swift` - Audio capture (mic fix applied here)

## Related Fixes Already Applied

1. **Microphone capture fix**: Force Float32 format for AVAudioEngine tap to ensure `floatChannelData` is available
2. **Sample counting fix**: Move `totalMicSamples` increment before sync guard
3. **Buffer averaging fix**: Reduce `kBuffersToAverage` from 50 to 12

## Next Steps

1. Build and launch with new diagnostic logging
2. Capture logs during a test recording
3. Analyze INDEX and LOOKUP logs to identify the root cause
4. Apply targeted fix based on findings
5. Verify 0% → >0% match rate improvement
