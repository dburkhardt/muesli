# AEC (Acoustic Echo Cancellation) Architecture

This document is the authoritative reference for AEC in Muesli. It covers theory, implementation details, debugging guidance, and lessons learned. Other agents should consult this document when troubleshooting or extending AEC functionality.

## Table of Contents

1. [Overview](#overview)
2. [Theory: How AEC Works](#theory-how-aec-works)
3. [Muesli's AEC Architecture](#mueslis-aec-architecture)
4. [Stream Synchronization](#stream-synchronization)
5. [Buffer Gap Handling and Continuity](#buffer-gap-handling-and-continuity)
6. [The NLMS Algorithm](#the-nlms-algorithm)
7. [Configuration Parameters](#configuration-parameters)
8. [Parameter Tuning Guide](#parameter-tuning-guide)
9. [Testing and Quality Metrics](#testing-and-quality-metrics)
10. [Double-Talk Detection (DTD)](#double-talk-detection-dtd)
11. [Diagnostic Logging](#diagnostic-logging)
12. [Common Failure Modes](#common-failure-modes)
13. [Debugging Checklist](#debugging-checklist)
14. [Lessons Learned](#lessons-learned)
15. [Future Improvements](#future-improvements)
16. [References and Standards](#references-and-standards)

---

## Overview

### What is AEC?

Acoustic Echo Cancellation removes the echo heard when a microphone picks up audio from nearby speakers. In Muesli's context:

- **Echo source**: System audio (meeting participants' voices) plays through speakers
- **Echo path**: Sound travels from speakers → room → microphone
- **Problem**: Microphone captures both the user's voice AND the speakers' output
- **Solution**: Predict and subtract the echo from the microphone signal

### Why Muesli Needs AEC

Without AEC, transcriptions show duplicate content:
- "Them" segments contain what the remote participant said
- "Me" segments ALSO contain what the remote participant said (as echo)

With AEC, the microphone stream is cleaned, and "Me" segments contain only the local user's voice.

---

## Theory: How AEC Works

### The Echo Path Model

```
System Audio ────┬─────────────────────────────> File Output (audio.caf)
                 │
                 │   DAC → Speakers → Room → Microphone → ADC
                 │   └──────────── Echo Path ────────────┘
                 │                    │
                 ▼                    ▼
           AEC Reference ────> Adaptive Filter ────> Predicted Echo
                                                            │
                                                            ▼
Microphone ─────────────────────────────────────────> Subtract ────> Clean Audio
                                                                          │
                                                                          ▼
                                                              File Output (microphone.caf)
                                                              Transcription (16kHz)
```

### Key Concepts

1. **Reference Signal**: The system audio we're trying to remove (what's playing through speakers)
2. **Echo Path**: The acoustic transformation from speakers to microphone (includes room reflections)
3. **Adaptive Filter**: Learns to model the echo path in real-time
4. **Error Signal**: Microphone minus predicted echo = clean audio (ideally)

### Time Alignment is Critical

For AEC to work, the reference signal must be **time-aligned** with when that audio appears in the microphone. This requires accounting for:

1. **DAC Latency**: Digital-to-analog conversion (~1-5ms)
2. **Acoustic Propagation**: Speed of sound through air (~3ms per meter)
3. **ADC Latency**: Analog-to-digital conversion (~1-5ms)
4. **Buffer Latency**: Audio processing pipeline delays

Total acoustic delay is typically 15-50ms, configured via `AudioConfiguration.aecAcousticDelayMs`.

---

## Muesli's AEC Architecture

### Component Overview

```
┌────────────────────────────────────────────────────────────────────────┐
│                         RecordingController                             │
│                                                                         │
│  ┌──────────────────────┐        ┌──────────────────────────┐         │
│  │   AudioCaptureService │        │   EchoCancellationService │         │
│  │                       │        │                           │         │
│  │  SCStream (48kHz)     │───────▶│  storeSystemAudio()       │         │
│  │  System Audio         │        │  (reference signal)       │         │
│  │                       │        │                           │         │
│  │  AVAudioEngine (48kHz)│───────▶│  processMicrophoneAudio() │────────▶│ Clean Mic
│  │  Microphone           │        │  (echo removal)           │         │
│  └──────────────────────┘        └──────────────────────────┘         │
│                                                                         │
│  Both streams → FileOutputService (raw files)                          │
│  Clean mic → TranscriptionService (16kHz resampled)                    │
└────────────────────────────────────────────────────────────────────────┘
```

### Data Flow

1. **System Audio Path**:
   - ScreenCaptureKit delivers CMSampleBuffer (48kHz stereo Float32)
   - RecordingController extracts samples and sends to `EchoCancellationService.storeSystemAudio()`
   - Samples are indexed and stored in a ring buffer for reference lookup

2. **Microphone Audio Path**:
   - AVAudioEngine delivers CMSampleBuffer (48kHz mono Float32)
   - RecordingController sends to `EchoCancellationService.processMicrophoneAudio()`
   - AEC looks up time-aligned reference samples and applies NLMS filter
   - Returns cleaned microphone audio

### Key Files

| File | Responsibility |
|------|----------------|
| `EchoCancellationService.swift` | Core AEC implementation (NLMS, sync, buffering) |
| `AudioConfiguration.swift` | AEC parameters (delay, filter length, learning rate) |
| `RecordingController.swift` | Orchestrates audio flow, calls AEC methods |

---

## Stream Synchronization

### The Synchronization Problem

The two audio streams (system and microphone) are delivered by different frameworks with different latencies:

| Stream | Framework | Typical Latency |
|--------|-----------|-----------------|
| System Audio | ScreenCaptureKit | ~300-400ms |
| Microphone | AVAudioEngine | ~50-100ms |

**Result**: Microphone buffers arrive ~250-350ms before the corresponding system audio buffers.

### Why This Matters

AEC uses sample indices to find reference audio. If we reset both counters to 0 when streams "synchronize," the microphone counter races ahead:

```
Time:     0ms      100ms     200ms     300ms     400ms
Mic:      [buf0]   [buf1]    [buf2]    [buf3]    [buf4]
System:                                 [buf0]    [buf1]

Mic sample count:  0→960→1920→2880→3840→4800
Sys sample count:                  0→960→1920

When mic requests sys sample 4800, system only has up to 1920.
MATCH MISS! (0% match rate)
```

### The Delivery Offset Solution

We measure the **delivery offset** between streams by recording buffer arrival times:

```swift
// AECState fields for offset tracking
var systemAudioBufferTimes: [Double] = []   // CACurrentMediaTime() for first 50 buffers
var microphoneBufferTimes: [Double] = []    // CACurrentMediaTime() for first 50 buffers
var deliveryOffsetSamples: Int64 = 0        // Positive = mic ahead
var offsetCalculated: Bool = false
```

**Calculation (after 50 buffers from each stream)**:
```swift
let avgSysTime = systemAudioBufferTimes.reduce(0, +) / 50.0
let avgMicTime = microphoneBufferTimes.reduce(0, +) / 50.0
let offsetSeconds = avgSysTime - avgMicTime  // Positive if mic ahead
deliveryOffsetSamples = Int64(offsetSeconds * 48000)  // Convert to samples
```

**Compensation in target index calculation**:
```swift
// When looking up system audio for microphone sample N:
let targetSysIndex = micStartIndex - acousticDelaySamples - deliveryOffsetSamples
```

### Why 50 Buffers?

Testing revealed that buffer timing is chaotic immediately after recording starts (especially after system sleep/wake). Averaging 50 buffers (~1 second) provides stable measurements.

| Measurement | Single Buffer | 50-Buffer Average |
|-------------|---------------|-------------------|
| Jitter | 70-530ms observed | <5ms variance |
| Reliability | Poor | Excellent |

### Synchronization State Machine

```
                    ┌──────────────────────────────────────┐
                    │           INITIAL STATE              │
                    │  offsetCalculated = false            │
                    │  streamsSynchronized = false         │
                    └──────────────────┬───────────────────┘
                                       │
                                       │ First buffer arrives
                                       ▼
                    ┌──────────────────────────────────────┐
                    │        COLLECTING TIMESTAMPS         │
                    │  Recording arrival times for         │
                    │  first 50 buffers from each stream   │
                    │  Mic audio: pass-through (no AEC)    │
                    │  Sys audio: buffered with indices    │
                    └──────────────────┬───────────────────┘
                                       │
                                       │ 50 buffers from BOTH streams
                                       ▼
                    ┌──────────────────────────────────────┐
                    │         OFFSET CALCULATED            │
                    │  Calculate deliveryOffsetSamples     │
                    │  Set offsetCalculated = true         │
                    │  Set streamsSynchronized = true      │
                    └──────────────────┬───────────────────┘
                                       │
                                       ▼
                    ┌──────────────────────────────────────┐
                    │           AEC ACTIVE                 │
                    │  Full echo cancellation enabled      │
                    │  Reference lookup uses offset        │
                    └──────────────────────────────────────┘
```

**Important**: We do NOT reset sample counters after synchronization. The buffers are already indexed with running counts, and resetting would cause index mismatches.

### Timeout Fallback

If offset calculation doesn't complete within 5 seconds (e.g., one stream fails to start), we fall back to pass-through mode:

```swift
if now.timeIntervalSince(startTime) > syncTimeoutSeconds && !streamsSynchronized {
    streamsSynchronized = true  // Allow processing to continue
    // AEC will likely have 0% match rate, but at least audio is recorded
}
```

---

## Buffer Gap Handling and Continuity

### The Problem: ScreenCaptureKit Buffer Gaps

ScreenCaptureKit on macOS can drop audio buffers under certain conditions, causing gaps in the audio stream. This is a [known macOS issue](https://nonstrict.eu/blog/2024/handling-audio-capture-gaps-on-macos). Without compensation, these gaps cause:

1. **Sample count drift**: System audio accumulates samples slower than wall-clock time
2. **Index mismatch**: `targetSysIndex` calculation drifts outside the valid buffer range
3. **Match rate degradation**: AEC match rate drops from ~95% to <10% over time

### The Solution: Wall-Clock-Based Gap Detection

We use `CACurrentMediaTime()` (monotonic, immune to clock adjustments) to detect gaps between buffer deliveries. When a gap exceeds the threshold, we fill it with silence samples.

```
Buffer 1 arrives at t=0     → Store samples [0-960]
Buffer 2 arrives at t=120ms → Expected: 5760 samples elapsed
                             → Actual: 960 samples delivered
                             → Gap: 4800 samples (100ms)
                             → Fill: Insert 4800 silence samples
                             → Store actual buffer [5760-6720]
```

### Gap Detection Algorithm

```swift
// Wall-clock gap detection (simplified)
let elapsed = CACurrentMediaTime() - lastBufferTime
let expectedSamples = Int64(elapsed * 48000)
let actualSamples = Int64(samples.count)
let gapSamples = expectedSamples - actualSamples

if gapSamples > gapThreshold {  // 50ms = 2400 samples
    // Fill gap with silence
    let silenceBuffer = IndexedBuffer(
        samples: Array(repeating: 0.0, count: Int(gapSamples)),
        startSampleIndex: totalSystemSamples
    )
    systemAudioBuffers.append(silenceBuffer)
    totalSystemSamples += gapSamples
}

// Always store actual buffer after gap fill
systemAudioBuffers.append(IndexedBuffer(
    samples: samples,
    startSampleIndex: totalSystemSamples
))
totalSystemSamples += Int64(samples.count)
```

### Configuration Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| `aecGapThresholdMs` | 50ms | Minimum gap size to trigger silence fill |
| `aecMaxGapMs` | 500ms | Maximum gap to fill (larger gaps clamped) |
| `maxSystemAudioBuffers` | 150 | Maximum buffers retained (~3s of audio) |

### Why 50ms Threshold?

ScreenCaptureKit typically delivers buffers every ~20ms. Normal jitter is 10-30ms. A 50ms threshold:
- Ignores normal delivery variance (false positives)
- Catches actual dropped buffers (gaps >50ms)
- Matches typical buffer drop patterns observed in production

### Why 500ms Maximum?

Gaps larger than 500ms likely indicate a stream restart rather than dropped buffers. Clamping prevents:
- Memory spikes from very large gaps
- Filling gaps that don't represent continuous audio

When gaps exceed 500ms, we log a warning for investigation.

### Silence Fill Rationale

Why fill with silence instead of interpolation?
- **Acoustically correct**: No system audio played during gap = no echo
- **Simple**: Zero samples = zero predicted echo = clean pass-through
- **Safe**: No risk of introducing artifacts from bad interpolation

### Integration with Stream Synchronization

Gap detection runs **during warmup** (before offset calculation completes):
1. Delivery offset uses wall-clock arrival times, not sample counts
2. Gap fills ensure sample indices remain continuous from recording start
3. When sync completes, `totalSystemSamples` accurately reflects real-time progression

This is safe because the offset calculation uses `CACurrentMediaTime()` timestamps, which are independent of the gap fill logic.

### Diagnostic Logging

| Log Message | Meaning |
|-------------|---------|
| `SYS_GAP: N samples (Xms)` | Gap detected and filled with silence |
| `SYS_GAP_LARGE: N samples clamped to 500ms` | Gap exceeded max, clamped |
| `SYS_EARLY: buffer N samples early` | Negative gap (logged, no action) |
| `MIC_GAP_DETECTED: N samples` | Mic gap detected (Phase 2 data) |
| `AEC_RECORDING_END: gaps=N, total=X, max=Y` | Recording summary |
| `DRIFT_WARNING: X% drift after Ns` | Periodic drift check (every 60s) |

### Testing Gap Detection

Unit tests use `MockTimeProvider` for deterministic timing:
```swift
func testGapFillsWithSilence() {
    mockTime.time = 0.0
    sut.storeSystemAudio(samples: generateSineWave(duration: 0.02))
    
    mockTime.time = 0.12  // 100ms gap
    sut.storeSystemAudio(samples: generateSineWave(duration: 0.02))
    
    XCTAssertEqual(sut.totalGapSamples, 4800)  // 100ms = 4800 samples
}
```

### Edge Cases

| Scenario | Handling |
|----------|----------|
| First buffer | Initialize timing, store buffer (no gap check) |
| Negative gap (early arrival) | Log debug, store normally (no counter decrement) |
| Large gap (>500ms) | Clamp to 500ms, log warning |
| Gap during warmup | Fill immediately (safe per above) |
| Rapid delivery after gap | Only first buffer triggers fill |
| Mic stream gaps | Logged only (Phase 2 - no fill currently) |

---

## The NLMS Algorithm

### Algorithm Overview

NLMS (Normalized Least Mean Squares) is an adaptive filter that learns to predict echo:

```
For each microphone sample m[n]:
    1. Get reference samples x[n-filterLength+1..n] from system audio
    2. Predict echo: ŷ[n] = Σ(w[k] * x[n-k]) for k=0..filterLength-1
    3. Compute error: e[n] = m[n] - ŷ[n]
    4. Update weights: w[k] += μ * e[n] * x[n-k] / (||x||² + ε)
    5. Output e[n] as clean audio
```

### Implementation Details

```swift
// Compute predicted echo
var predictedEcho: Float = 0.0
for j in 0..<filterLength {
    let sample = referenceBuffer.sample(at: filterLength - 1 - j)
    predictedEcho += filterCoefficients[j] * sample
}

// Error = microphone - predicted echo
let error = microphoneSamples[i] - predictedEcho

// Compute reference power for normalization
var referencePower: Float = epsilon
for j in 0..<filterLength {
    let sample = referenceBuffer.sample(at: filterLength - 1 - j)
    referencePower += sample * sample
}

// Update filter coefficients
let stepSize = learningRate / referencePower
for j in 0..<filterLength {
    let sample = referenceBuffer.sample(at: filterLength - 1 - j)
    filterCoefficients[j] += stepSize * error * sample
}
```

### Why NLMS Over LMS?

| Algorithm | Pros | Cons |
|-----------|------|------|
| LMS | Simple | Step size must be tuned for input level |
| **NLMS** | **Self-normalizing, works across volume levels** | Slightly more computation |

NLMS divides by signal power, making it robust to varying audio levels.

### Known Limitations

1. **No Double-Talk Detection (DTD)**: When both the user and remote participant speak simultaneously, NLMS may adapt incorrectly
2. **No Non-Linear Processing (NLP)**: Linear filter can't fully model speaker/room non-linearities
3. **Filter Length Constraint**: Echo path must be shorter than `filterLength × samplePeriod`

---

## Configuration Parameters

All AEC parameters are in `AudioConfiguration.swift`:

| Parameter | Value | Description |
|-----------|-------|-------------|
| `aecAcousticDelayMs` | 50ms | Expected DAC + propagation + ADC delay |
| `aecFilterLength` | 1024 taps | Echo path modeling capacity (~21ms at 48kHz) |
| `aecLearningRate` | 0.2 | NLMS step size (higher = faster adaptation, less stable) |

### In EchoCancellationService

| Parameter | Value | Description |
|-----------|-------|-------------|
| `maxDelayMs` | 3000ms | Ring buffer capacity for variable delivery latency |
| `kBuffersToAverage` | 12 | Buffers to average for offset calculation (~1 second) |
| `maxSystemAudioBuffers` | 150 | Maximum system audio buffers to retain (~3 seconds) |
| `syncTimeoutSeconds` | 5.0 | Timeout before fallback to pass-through |
| `maxReasonableOffset` | ±24000 samples | Sanity clamp (±500ms) |

### Important: `maxDelayMs` vs `acousticDelayMs`

These two parameters serve **different purposes** and are not interchangeable:

| Parameter | Purpose | Typical Value |
|-----------|---------|---------------|
| `acousticDelayMs` | Expected acoustic propagation delay (DAC → speakers → room → microphone → ADC) | 15-50ms |
| `maxDelayMs` | Ring buffer capacity to handle ScreenCaptureKit's variable delivery latency | 3000ms |

**Why `maxDelayMs` is much larger than `acousticDelayMs`:**

- ScreenCaptureKit and AVAudioEngine deliver audio buffers with different and variable latencies
- The microphone stream typically arrives 250-350ms before the corresponding system audio
- During the warmup period (~50 buffers), timing jitter can exceed 500ms
- `maxDelayMs: 3000` provides a generous 3-second buffer to ensure reference audio is available even in worst-case delivery scenarios

**Tuning Note (2026-01-25):** The current parameters are intentional but may need real-world tuning:
- If AEC shows 0% match rate, the issue is likely stream synchronization (delivery offset), not these parameters
- If echo remains after warmup with good match rate, consider increasing `acousticDelayMs` for setups with external speakers
- The large `maxDelayMs` is a safety margin and has minimal memory cost at 48kHz (3s ≈ 576KB)

---

## Parameter Tuning Guide

### When to Adjust Parameters

The default parameters are tuned for typical laptop setups (built-in speakers and microphone). Consider adjusting when:

| Scenario | Adjustment |
|----------|------------|
| External speakers (farther from mic) | Increase `aecAcousticDelayMs` to 70-100ms |
| High echo/reverberant room | Increase `aecFilterLength` to 2048 taps |
| Echo changes frequently | Increase `aecLearningRate` to 0.3-0.4 |
| Echo is stable | Decrease `aecLearningRate` to 0.1 for less noise |
| Headphones (no echo) | Consider disabling AEC entirely |

### Parameter Trade-offs

**Filter Length (`aecFilterLength`)**
```
Longer (2048+):
  ✅ Handles longer echo paths and room reverb
  ✅ Better for external speakers
  ❌ More CPU usage
  ❌ Slower convergence

Shorter (256-512):
  ✅ Faster convergence
  ✅ Lower CPU usage
  ❌ May not capture full echo path
  ❌ Residual echo in reverberant rooms
```

**Learning Rate (`aecLearningRate`)**
```
Higher (0.3-0.5):
  ✅ Faster adaptation to changing conditions
  ✅ Better tracking of moving speakers
  ❌ More noise in output (misadjustment)
  ❌ May diverge during double-talk

Lower (0.1-0.2):
  ✅ More stable, less noise
  ✅ Better steady-state performance
  ❌ Slower to adapt to changes
  ❌ Poor tracking of time-varying echo
```

### Advanced: Variable Step-Size (VSS-NLMS)

Industry-grade AEC implementations use **Variable Step-Size NLMS** (VSS-NLMS) which dynamically adjusts the learning rate:

| Phase | Step Size | Regularization | Rationale |
|-------|-----------|----------------|-----------|
| Initial convergence | High (~0.5-1.0) | Low | Fast adaptation to echo path |
| Steady-state | Low (~0.1) | High | Minimize misadjustment noise |
| Echo path change | High | Low | Re-adapt to new conditions |
| Double-talk detected | Zero (freeze) | N/A | Prevent divergence |

**Current Implementation**: Uses fixed step size (0.2). This is a known limitation - adding VSS-NLMS would improve both convergence speed and steady-state performance.

**Research Reference**: "Variable Step-Size NLMS Algorithm for Under-Modeling Acoustic Echo Cancellation" (2008) provides a practical VSS-NLMS that doesn't require a priori environmental information.

---

## Testing and Quality Metrics

### Objective Metrics

**Echo Return Loss Enhancement (ERLE)**

The primary objective metric for AEC quality:

```
ERLE = 10 × log₁₀(E[y²(n)] / E[ŷ²(n)])
```

Where:
- `y(n)` = microphone signal (with echo)
- `ŷ(n)` = enhanced signal (after AEC)

| ERLE Value | Quality |
|------------|---------|
| < 10 dB | Poor - significant echo remains |
| 10-20 dB | Acceptable for meetings |
| 20-30 dB | Good - echo barely noticeable |
| > 30 dB | Excellent - professional quality |

**Limitations**: ERLE is only valid for single-talk (far-end only) in quiet conditions. It doesn't measure double-talk performance.

**Echo Return Loss (ERL)**

Measures the acoustic attenuation in the loudspeaker-microphone path (before AEC):

```
ERL = 10 × log₁₀(E[x²(n)] / E[y²(n)])
```

Where:
- `x(n)` = far-end signal (system audio)
- `y(n)` = microphone signal

Typical values: 5-15 dB for laptop, 0-10 dB for external speakers.

### Subjective Metrics

**Mean Opinion Score (MOS)**

Recent AEC challenges (ICASSP 2021, INTERSPEECH 2021) prioritize MOS over objective metrics because ERLE doesn't correlate well with perceived quality in realistic conditions (background noise, reverberation, double-talk).

| MOS | Quality |
|-----|---------|
| 1 | Bad |
| 2 | Poor |
| 3 | Fair |
| 4 | Good |
| 5 | Excellent |

### Testing Procedure

1. **Single-talk test**: Play reference audio, record microphone, measure ERLE
2. **Double-talk test**: Play reference + speak into mic, check for distortion
3. **Convergence test**: Start recording, measure time to reach target ERLE
4. **Tracking test**: Change speaker position/volume, verify re-adaptation

### Match Rate as Proxy Metric

Muesli logs `MATCH: X/Y (Z%)` which indicates reference lookup success. This is a proxy for AEC health:

| Match Rate | Interpretation |
|------------|----------------|
| >95% | Excellent - sync working correctly |
| 80-95% | Good - some buffer drops acceptable |
| 50-80% | Degraded - investigate sync issues |
| <50% | Broken - AEC effectively disabled |

---

## Double-Talk Detection (DTD)

### Why DTD Matters

During double-talk (both users speaking), NLMS may adapt incorrectly:

```
Without DTD:
  Far-end speaks → Filter adapts correctly ✅
  Near-end speaks alone → Filter should freeze, but doesn't
  Both speak → Filter tries to cancel near-end speech ❌
              → Filter coefficients corrupt
              → Echo worsens after double-talk ends
```

### When DTD Becomes Critical

| Scenario | DTD Importance |
|----------|----------------|
| One-way presentation | Low - rarely double-talk |
| Interview (turns) | Medium - occasional overlap |
| Active discussion | High - frequent interruptions |
| Debate/argument | Critical - constant overlap |

For Muesli's meeting transcription use case, DTD is **medium priority** - most meetings have turn-taking patterns, but interruptions do occur.

### Simple DTD Approaches

**1. Geigel Detector (Simplest)**

Compares signal levels over a window:

```
DTD_ratio = max(|x[n-k]|) / |y[n]|  for k = 0..echo_path_length

if DTD_ratio < threshold:
    declare_double_talk()
    freeze_filter_adaptation()
```

- **Threshold**: Set near Echo Return Loss (ERL) value
- **Pros**: Simple, low CPU
- **Cons**: Threshold must track varying ERL; prone to false alarms

**2. Error Signal Variance Method**

Tracks the variance of the error signal:

```
During single-talk: error variance is low (filter converged)
During double-talk: error variance spikes (near-end speech appears)

if error_variance > threshold * baseline_variance:
    declare_double_talk()
```

- **Pros**: Works with standard NLMS, no extra signals needed
- **Cons**: Threshold tuning required; may miss gradual onset

**3. Cross-Correlation Method**

Correlates microphone with estimated echo:

```
correlation = correlate(microphone_signal, predicted_echo)

High correlation → single-talk (echo matches prediction)
Low correlation → double-talk (near-end speech decorrelates)
```

- **Pros**: More robust than Geigel
- **Cons**: Higher CPU, requires more signal history

### Current Implementation Status

Muesli does **not** implement DTD. This means:
- Filter may temporarily diverge during double-talk
- Echo suppression may degrade after prolonged double-talk
- Workaround: Lower learning rate (0.2) reduces divergence risk but slows adaptation

### Future DTD Integration

Priority: Medium (after core AEC is stable)

Recommended approach:
1. Start with Geigel detector (simple, low risk)
2. Add error variance method as backup
3. Freeze adaptation when either triggers
4. Tune thresholds based on real meeting recordings

---

## Diagnostic Logging

AEC logs to `DiagnosticLogger` under the `.aec` category.

### Key Log Messages

| Message | Meaning |
|---------|---------|
| `SYNC_OFFSET: delivery_offset=X samples (Yms), mic_ahead` | Offset calculated successfully |
| `SYNC_TIMEOUT: streams not synchronized after 5s` | Fallback to pass-through (one stream may have failed) |
| `MATCH: X/Y (Z%)` | Reference lookup success rate (logged every 100 calls) |
| `BUFFER_GAP: expected=X, got=Y` | Non-contiguous system audio buffers detected |
| `SYNC_WARNING: offset exceeds ±500ms, clamping` | Unusually large offset (may indicate clock issues) |

### Healthy Log Pattern

```
[AEC] SYNC_OFFSET: delivery_offset=14976 samples (312.0ms), mic_ahead, sync_after=1.042s
[AEC] MATCH: 95/100 (95.0%)
[AEC] MATCH: 195/200 (97.5%)
[AEC] MATCH: 297/300 (99.0%)
```

### Unhealthy Log Pattern

```
[AEC] SYNC: streams synchronized in 0.031s    ← OLD: immediate sync (bad)
[AEC] MATCH: 2/100 (2.0%)                      ← Near 0% = streams misaligned
[AEC] MATCH: 2/200 (1.0%)
```

---

## Common Failure Modes

### 1. 0% Match Rate

**Symptom**: `MATCH: 0/N (0.0%)` or very low percentage

**Causes**:
- Delivery offset not calculated (check for `SYNC_OFFSET` log)
- Immediate sync before offset measured (streams synchronized too early)
- System audio discarded during warmup (not buffered)

**Fix**: Ensure `streamsSynchronized` is only set after `offsetCalculated` becomes true.

### 2. No SYNC_OFFSET Log

**Symptom**: No `SYNC_OFFSET` message appears

**Causes**:
- `checkAndSynchronizeStreams()` not called after streams have 50 buffers
- Offset calculation code path not executed

**Fix**: Call `checkAndSynchronizeStreams()` on EVERY buffer until `offsetCalculated` is true:
```swift
if !state.offsetCalculated {
    checkAndSynchronizeStreams(&state)
}
```

### 3. Sample Index Mismatch

**Symptom**: `targetSysIndex` doesn't fall within available buffer range

**Causes**:
- Sample counters reset after buffers already indexed
- Delivery offset not compensated

**Fix**: Never reset `totalSystemSamples`/`totalMicSamples` after sync. Buffer indices must remain consistent.

### 4. Extreme Offset Values

**Symptom**: `SYNC_WARNING: offset exceeds ±500ms`

**Causes**:
- System clock adjustment during measurement
- Hardware malfunction
- Very unusual audio setup

**Mitigation**: Offset is clamped to ±500ms. AEC may be suboptimal but won't fail catastrophically.

---

## Debugging Checklist

When AEC isn't working, check these in order:

### 1. Verify Streams Are Delivering Audio
```bash
# Check for buffer delivery logs
grep "storeSystemAudio\|processMicrophoneAudio" ~/Library/Application\ Support/Muesli/Logs/muesli-*.log
```

### 2. Check Offset Calculation
```bash
# Look for SYNC_OFFSET log
grep "SYNC_OFFSET" ~/Library/Application\ Support/Muesli/Logs/muesli-*.log
```
- If missing: offset calculation never triggered
- If present: note the offset value (should be ~250-350ms for typical setups)

### 3. Check Match Rate
```bash
# Look for MATCH rate logs
grep "MATCH:" ~/Library/Application\ Support/Muesli/Logs/muesli-*.log | tail -20
```
- >90%: AEC is working well
- 1-10%: Stream alignment issue
- 0%: Complete misalignment or no reference audio

### 4. Verify State Transitions
Trace through the code to ensure:
1. `systemAudioBufferTimes` and `microphoneBufferTimes` are populated
2. `checkAndSynchronizeStreams` is called repeatedly until offset calculated
3. `streamsSynchronized` is set ONLY after `offsetCalculated` is true
4. Sample counters are NOT reset after synchronization

---

## Lessons Learned

### Lesson 1: Code Exists ≠ Code Executes

**Problem**: Offset calculation code was written but never executed because `checkAndSynchronizeStreams()` was only called once when each stream started.

**Solution**: Call the sync function on every buffer until offset is calculated:
```swift
if !state.offsetCalculated {
    checkAndSynchronizeStreams(&state)
}
```

**Prevention**: Always trace execution paths when adding new logic. Verify conditions under which code runs.

### Lesson 2: Don't Discard Audio During Warmup

**Problem**: System audio was discarded before `streamsSynchronized` became true. When sync happened (with offset), there was no reference audio at index 0.

**Solution**: Always buffer system audio, even during warmup:
```swift
// CRITICAL: Always buffer system audio
// Previously we discarded pre-sync samples, but with deferred sync
// this caused 0% match rate since there was no reference audio
let startIndex = state.totalSystemSamples
state.systemAudioBuffers.append(IndexedBuffer(samples: samples, startSampleIndex: startIndex))
state.totalSystemSamples += Int64(samples.count)
```

### Lesson 3: Don't Reset Sample Counters After Sync

**Problem**: Resetting `totalSystemSamples = 0` after sync caused index mismatch - buffers were indexed with old counts but lookups used new counts.

**Solution**: Never reset counters. Let them run continuously from recording start.

### Lesson 4: Sync AFTER Offset Calculated, Not Immediately

**Problem**: Setting `streamsSynchronized = true` as soon as both streams started meant AEC operated with `deliveryOffsetSamples = 0` during the measurement window (~1 second).

**Solution**: Only set `streamsSynchronized = true` after offset calculation completes:
```swift
if !state.offsetCalculated && haveEnoughBuffers {
    // Calculate offset...
    state.deliveryOffsetSamples = offsetSamples
    state.offsetCalculated = true
    state.streamsSynchronized = true  // NOW sync, with correct offset
}
```

### Lesson 5: Use Monotonic Time for Measurements

**Problem**: Using `Date()` or `CFAbsoluteTimeGetCurrent()` could give incorrect measurements if system clock adjusts during recording.

**Solution**: Use `CACurrentMediaTime()` which is based on `mach_absolute_time()` and immune to clock adjustments.

---

## Future Improvements

### Priority 1: Double-Talk Detection (DTD)

**Status**: Not implemented  
**Impact**: Medium - filter may diverge during interruptions  
**Effort**: Low-Medium

See [Double-Talk Detection section](#double-talk-detection-dtd) for implementation approaches. Recommended starting point: Geigel detector with error variance backup.

### Priority 2: Variable Step-Size NLMS (VSS-NLMS)

**Status**: Not implemented (uses fixed step size)  
**Impact**: Medium - faster convergence + better steady-state  
**Effort**: Medium

Implement adaptive step-size control based on error signal characteristics:
- High step size during convergence
- Low step size at steady state
- Freeze during double-talk (requires DTD first)

Reference: "New variable step-size fast NLMS algorithm for non-stationary systems" (2023)

### Priority 3: Non-Linear Processing (NLP)

**Status**: Not implemented  
**Impact**: Low-Medium - improves residual echo suppression  
**Effort**: Medium-High

Speakers and rooms introduce non-linearities that linear NLMS can't fully model. NLP would:
1. Apply residual echo suppression after NLMS
2. Use spectral subtraction or Wiener filtering
3. Target the remaining echo that NLMS couldn't remove

### Priority 4: Automatic Delay Estimation

**Status**: Not implemented (uses fixed 50ms)  
**Impact**: Low - current value works for most setups  
**Effort**: Medium

Cross-correlate system audio with microphone to find peak delay. Would handle:
- External speakers at varying distances
- Different audio hardware latencies
- Dynamic speaker position changes

### Priority 5: WebRTC AEC3 Integration

**Status**: Not implemented  
**Impact**: High - production-quality AEC  
**Effort**: High

WebRTC's AEC3 is a production-quality implementation with:
- Built-in delay estimation
- Double-talk detection
- Non-linear processing
- Extensive tuning for real-world conditions

This would be a significant undertaking but would provide the best quality. Consider as a long-term goal if current NLMS proves insufficient.

---

## References and Standards

### Academic References

| Topic | Reference |
|-------|-----------|
| NLMS Algorithm | Haykin, S. "Adaptive Filter Theory" (5th ed.) |
| VSS-NLMS | "Variable Step-Size NLMS Algorithm for Under-Modeling AEC" (2008) |
| Fast VSS-NLMS | "New variable step-size fast NLMS algorithm" (Springer, 2023) |
| DTD Approaches | "Comparison of Multichannel Doubletalk Detectors for AEC" (EUSIPCO 2015) |
| AEC Evaluation | "ICASSP 2021 Acoustic Echo Cancellation Challenge" |

### Industry Standards

| Standard | Relevance |
|----------|-----------|
| **ITU-T G.168** | Digital network echo cancellers (reference for ERLE targets) |
| **AES11-2020** | Digital audio synchronization (relevant to stream sync approach) |
| **RFC 6051** | Rapid synchronization of RTP flows (background on audio sync) |

### Implementation References

| Resource | URL |
|----------|-----|
| WebRTC AEC3 | https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_processing/aec3/ |
| Apple ScreenCaptureKit | https://developer.apple.com/documentation/screencapturekit |
| Apple AVAudioEngine | https://developer.apple.com/documentation/avfaudio/avaudioengine |
| VOCAL Technologies AEC | https://vocal.com/echo-cancellation/ (good tutorials) |

### Related Muesli Documentation

| Document | Content |
|----------|---------|
| `spec/audio_pipeline.md` | Overall audio architecture, sample rates, file formats |
| `AGENTS.md` | Build commands, thread safety requirements |
| `AudioConfiguration.swift` | All AEC parameters with documentation |

---

## Document History

| Date | Change | Author |
|------|--------|--------|
| 2026-01-24 | Initial creation based on stream offset fix debugging session | Agent |
| 2026-01-24 | Added: Parameter tuning guide, testing metrics (ERLE/ERL/MOS), expanded DTD section with simple approaches, VSS-NLMS discussion, standards references | Agent |
| 2026-01-25 | Added: Buffer Gap Handling and Continuity section documenting wall-clock-based gap detection with silence fill per AEC clock drift fix plan | Agent |
