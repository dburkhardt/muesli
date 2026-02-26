# AEC (Acoustic Echo Cancellation) Architecture

This document is the authoritative reference for AEC in Muesli. It covers theory, implementation details, debugging guidance, and lessons learned. Other agents should consult this document when troubleshooting or extending AEC functionality.

## Table of Contents

1. [Overview](#overview)
2. [Theory: How AEC Works](#theory-how-aec-works)
3. [Core Audio Taps Architecture (macOS 14.2+)](#core-audio-taps-architecture-macos-142)
4. [Muesli's AEC Architecture](#mueslis-aec-architecture)
5. [Audio Synchronizer](#audio-synchronizer)
6. [WebRTC AEC3 Integration](#webrtc-aec3-integration)
7. [Stream Synchronization (Legacy ScreenCaptureKit)](#stream-synchronization-legacy-screencapturekit)
8. [Buffer Gap Handling and Continuity](#buffer-gap-handling-and-continuity)
9. [The NLMS Algorithm](#the-nlms-algorithm)
10. [Configuration Parameters](#configuration-parameters)
11. [Parameter Tuning Guide](#parameter-tuning-guide)
12. [Testing and Quality Metrics](#testing-and-quality-metrics)
13. [Double-Talk Detection (DTD)](#double-talk-detection-dtd)
14. [Diagnostic Logging](#diagnostic-logging)
15. [2026-01-27 Investigation: WebRTC AEC3 Not Converging](#2026-01-27-investigation-webrtc-aec3-not-converging)
16. [2026-01-27 Follow-up: External Delay Estimator Unsupported](#2026-01-27-follow-up-external-delay-estimator-unsupported)
17. [Common Failure Modes](#common-failure-modes)
18. [Debugging Checklist](#debugging-checklist)
19. [Lessons Learned](#lessons-learned)
20. [Implementation Status](#implementation-status)
21. [Future Improvements](#future-improvements)
22. [Best Practices](#best-practices)
23. [References and Standards](#references-and-standards)

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

## Core Audio Taps Architecture (macOS 14.2+)

### Overview

**IMPORTANT: This section reflects the current implementation (January 2026).**

Muesli now uses Core Audio process taps for system audio capture on macOS 14.2+. This replaces ScreenCaptureKit and provides:

- **Single clock domain**: Tap and mic use the same sample rate clock
- **Sample-index alignment**: Precise pairing without timestamp drift
- **True process exclusion**: Muesli's own audio is excluded from capture
- **Lower latency**: Direct device access vs ScreenCaptureKit buffering

### Platform Requirements

| Feature | Minimum macOS Version | Notes |
|---------|----------------------|-------|
| `AudioHardwareCreateProcessTap` | 14.2+ | Core tap creation API |
| `CATapDescription` | 14.2+ | Tap configuration class |
| `stereoGlobalTapButExcludeProcesses` | 14.2+ | Process exclusion initializer |
| System audio capture permission | 14.4+ | TCC privacy prompt |

**Note**: The original plan mentioned "macOS 26 Tahoe+ only" - this was incorrect. Core Audio taps are available starting in macOS 14.2 (Sonoma).

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                 Output Tap (Core Audio)                      │
│     AudioHardwareCreateProcessTap + CATapDescription         │
│     stereoGlobalTapButExcludeProcesses (excludes Muesli)     │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│           Tap-Only Aggregate Device                          │
│    kAudioAggregateDeviceTapListKey + TapAutoStart           │
│    NO mic subdevice - tap only                              │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
                 IOProc Callback (RT-safe)
                 (copy samples + timestamps only)
                           │
                           ▼
                    TapCaptureRing (render)
                    Lock-free, 600ms capacity

┌─────────────────────────────────────────────────────────────┐
│                 Mic Capture (AVAudioEngine)                  │
│        (supports user device selection)                      │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
                    MicCaptureRing (capture)
                    Lock-free, 250ms capacity

                 ┌─────────────────────────────────┐
                 │          AudioSynchronizer       │
                 │  - sample-index timeline         │
                 │  - bounded jitter buffers        │
                 │  - discontinuity detection       │
                 │  - CoarseDelayController         │
                 │  - DriftTracker + resampler      │
                 └─────────────────┬───────────────┘
                                   │
                                   ▼
                         AECProcessor (render→capture)
                                   │
                ┌──────────────────┴──────────────────┐
                │                                      │
                ▼                                      ▼
       FileOutputService                   TranscriptionService
```

### Key Components

| File | Responsibility |
|------|----------------|
| `CoreAudioTapManager.swift` | Tap lifecycle, self-tests, IOProc callback |
| `AggregateDeviceManager.swift` | Creates tap-only aggregate device |
| `CoreAudioHelpers.swift` | Core Audio utilities |
| `TapCaptureRing.swift` | Lock-free ring for render (600ms) |
| `MicCaptureRing.swift` | Lock-free ring for capture (250ms) |
| `AudioSynchronizer.swift` | Sample-index pairing, state machine |
| `CoarseDelayController.swift` | Hysteresis + slew-limited delay |
| `DriftTracker.swift` | ppm drift estimation + adaptive resampler |
| `Muesli-CoreAudio-Bridging-Header.h` | C headers for CATapDescription |

### Tap Creation Process

1. **Get Muesli's PID** for exclusion
2. **Convert PID to AudioObjectID** via `kAudioHardwarePropertyTranslatePIDToProcessObject`
3. **Create CATapDescription** using `stereoGlobalTapButExcludeProcesses`
4. **Call AudioHardwareCreateProcessTap** to create the tap
5. **Create aggregate device** with tap in `kAudioAggregateDeviceTapListKey`
6. **Start IOProc** on the aggregate device

```swift
// Simplified tap creation flow
let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: processObjectIDs)
tapDescription.name = "Muesli System Audio Tap"
tapDescription.uuid = UUID()
tapDescription.isPrivate = true
tapDescription.muteBehavior = .unmuted  // Don't mute tapped audio

var tapID: AudioObjectID = kAudioObjectUnknown
AudioHardwareCreateProcessTap(tapDescription, &tapID)

let aggregateDescription: [String: Any] = [
    kAudioAggregateDeviceNameKey: "Muesli Tap Device",
    kAudioAggregateDeviceUIDKey: aggregateUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceTapListKey: [tapUID],
    kAudioAggregateDeviceTapAutoStartKey: true
]
AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &deviceID)
```

### Permission Model

**IMPORTANT: `NSAudioCaptureUsageDescription` is a real Info.plist key and is required for system audio capture.**

The permission model for Core Audio taps:

1. **No explicit preflight check** like `CGPreflightScreenCaptureAccess()` for ScreenCaptureKit
2. **TCC prompt happens automatically** when `AudioHardwareCreateProcessTap` is first called (requires `NSAudioCaptureUsageDescription`)
3. **If denied**: The API may return silence with no programmatic "denied" status
4. **Detection**: Prolonged near-zero RMS after a known system sound = "not authorized"

**Current implementation** (`PermissionManager.swift`):
- Assumes permission is granted after onboarding completes
- Actual permission check happens when tap is created
- `audioCaptureGranted` flag is set optimistically

**Required Info.plist keys**:
- `NSAudioCaptureUsageDescription` - for system audio capture (required for taps)
- `NSMicrophoneUsageDescription` - for microphone access (required)
- `NSScreenCaptureUsageDescription` - keep while ScreenCaptureKit fallback exists

### IOProc RT-Safety Checklist

The IOProc callback (`CoreAudioTapManager.handleIOProc`) must be real-time safe:

- ✅ **No malloc/new** - uses pre-allocated ring buffers
- ✅ **No locks** - only lock-free ring buffer operations
- ✅ **No Objective-C/Swift ARC work** - pure memory copies
- ✅ **No logging** - deferred to worker thread
- ✅ **No syscalls** - no file I/O, no network

All format conversion, framing, and AEC processing happens on a dedicated audio worker thread.

### Self-Tests

The tap manager runs two self-tests to verify correct operation:

**Self-test A: System sound present**
1. Play a known system sound (not from Muesli)
2. Within 2 seconds, tap RMS must exceed threshold for N frames

**Self-test B: Muesli excluded**
1. Check that tap RMS stays near-zero when only Muesli might be outputting

If either fails, the system degrades to mic-only mode with actionable UI guidance.

### Device Topology Detection

| Mode | Condition | AEC Behavior |
|------|-----------|--------------|
| **Headset** | Input UID == Output UID (e.g., AirPods) | AEC off or very conservative |
| **Speakerphone** | USB mic + BT speakers, or different UIDs | Full AEC with robust sync |

On route change: flush rings, reset synchronizer, reset AEC adaptation state.

---

## Audio Synchronizer

### Overview

The `AudioSynchronizer` replaces the legacy delivery-time-based synchronization with **sample-index timeline matching**. This is more robust because it doesn't depend on framework-specific delivery timing.

### State Machine

```
                    ┌──────────────────────────────────────┐
                    │           INITIALIZING               │
                    │  Waiting for data in both rings      │
                    └──────────────────┬───────────────────┘
                                       │ Both rings have data
                                       ▼
                    ┌──────────────────────────────────────┐
                    │            PRIMING                   │
                    │  Building render lead to target      │
                    │  Target: 200ms (150-300ms band)      │
                    └──────────────────┬───────────────────┘
                                       │ Render lead in band +
                                       │ no recent discontinuity
                                       ▼
                    ┌──────────────────────────────────────┐
                    │             STABLE                   │
                    │  Normal operation, AEC enabled       │
                    └──────────────────┬───────────────────┘
                                       │ Discontinuity detected
                                       ▼
                    ┌──────────────────────────────────────┐
                    │            UNSTABLE                  │
                    │  AEC adaptation frozen               │
                    │  Re-priming to restore lead          │
                    └──────────────────────────────────────┘
```

### Jitter Buffer Policy (Speakerphone Mode)

| Parameter | Value | Notes |
|-----------|-------|-------|
| Target render lead | 200ms | Default target |
| Allowed band | 150-300ms | Valid range |
| Render buffer max | 600ms | Hard cap |
| Capture buffer max | 250ms | Hard cap |

**Overflow policy**:
- If render > max: Drop oldest render samples until render ≈ target lead
- If capture > max: Trigger discontinuity reset

**Underflow policy**:
- If render underflows during pairing: Mark UNSTABLE, freeze AEC, re-prime

### CoarseDelayController

Controls coarse delay estimation with conservative adaptation:

| Parameter | Value | Notes |
|-----------|-------|-------|
| Deadband (hysteresis) | 15ms (720 samples) | Ignore smaller changes |
| Slew rate | 1ms/sec (48 samples/sec) | Max slew toward target |
| Clamp range | 0-500ms | Hard limits |
| Stability threshold | 10ms for 5+ seconds | Definition of "stable" |

**Update gating**: Only accept delay updates during:
- Far-end dominant (or strong correlation)
- Alignment already mostly stable
- No recent discontinuity (10+ seconds)

### DriftTracker

Tracks clock drift between render and capture streams (e.g., USB mic + BT speakers have different clock domains):

- Measures sample rate deviation from expected 48kHz
- Computes relative drift in ppm (parts per million)
- Maximum reasonable drift: ±500 ppm
- Minimum valid estimate: 100 measurements (~10 seconds)
- Provides `resampleRatio` for adaptive resampling

### Discontinuity Detection

Thresholds (mSampleTime-based):
- **Backward jump**: deltaSamples ≤ 0
- **Large forward jump**: deltaSamples > expectedSamplesPerCallback × 8

On discontinuity:
1. Flush both rings
2. Re-prime jitter buffer to target render lead
3. Mark alignment UNSTABLE for 2+ seconds
4. Reset WebRTC AEC adaptation state

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

## WebRTC AEC3 Integration

### Overview

As of January 2026, Muesli supports **WebRTC AEC3** as the default echo cancellation implementation, with NLMS available as a fallback. WebRTC AEC3 provides significantly better echo suppression (25-35 dB ERLE vs 10-15 dB with NLMS).

**Library Version**: webrtc-audio-processing v2.x (FreeDesktop fork)

### API Changes in v2.x

**IMPORTANT**: The original plan mentioned "DelayAgnostic + ExtendedFilter" configuration. These are NOT explicit configuration options in webrtc-audio-processing v2.x.

| Feature | v1.x API | v2.x API (Current) |
|---------|----------|-------------------|
| Creation | `AudioProcessing::Create()` returns raw pointer | Returns `rtc::scoped_refptr<AudioProcessing>` |
| Config | `EchoCanceller3Config` struct | `AudioProcessing::Config` with `echo_canceller` field |
| Delay | External delay estimator configurable | Internal delay estimation only |
| Modes | Multiple echo control modes | `enabled` + `mobile_mode` flags |

**Current configuration** (from `WebRTCAECBridge.mm`):
```cpp
webrtc::AudioProcessing::Config config;
config.echo_canceller.enabled = true;
config.echo_canceller.mobile_mode = false;  // Desktop mode
config.gain_controller1.enabled = false;    // No AGC
config.noise_suppression.enabled = false;   // No NR
_apm->ApplyConfig(config);
```

### External Delay Estimator Status

**The external delay estimator is NOT available in the bundled v2.x framework.**

- `set_stream_delay_ms()` may be called but is not honored by AEC3
- AEC3 uses internal delay estimation only
- This means aligned-feed mode (where Swift pre-aligns frames) removes the timing signal AEC3 needs
- Workaround: Let render arrive naturally before capture to preserve timing information

### Hybrid Synchronization Architecture (Legacy ScreenCaptureKit)

**Note**: This section describes the legacy ScreenCaptureKit synchronization. With Core Audio taps, the `AudioSynchronizer` handles alignment instead.

When using ScreenCaptureKit, the audio pipeline had an unusual timing characteristic: microphone audio arrived 250-350ms before system audio due to:
- ScreenCaptureKit delivery latency for system audio
- AVAudioEngine direct capture for microphone (near-instant)

WebRTC AEC3 expects render (system) audio to arrive **at or before** capture (mic) with max ~128ms offset. The hybrid synchronization approach was used to bridge this gap:

```
┌─────────────────────────────────────────────────────────────────────────┐
│              EchoCancellationServiceWebRTC (Swift)                       │
│                                                                          │
│  STEP 1: Buffer BOTH streams during warmup (~1 second)                  │
│  ┌──────────────────────┐       ┌──────────────────────┐                │
│  │ System Audio         │       │ Microphone           │                │
│  │ Ring Buffer          │       │ Ring Buffer          │                │
│  │ (500ms capacity)     │       │ (500ms capacity)     │                │
│  └──────────┬───────────┘       └──────────┬───────────┘                │
│             │                              │                             │
│  STEP 2: Calculate offset from delivery times                           │
│  offset = avg(sysTime) - avg(micTime) ≈ +300ms (system arrives later)   │
│             │                              │                             │
│  STEP 3: When processing mic frame N, find MATCHING system frame        │
│             │                              │                             │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  findMatchingSystemAudio(micSampleIndex - offsetSamples)          │   │
│  │  → Returns time-aligned system audio for this mic frame           │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│             │                              │                             │
│  STEP 4: Feed ALIGNED frames to WebRTC (render THEN capture)           │
│             ▼                              ▼                             │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │              WebRTCAECBridge (ObjC++ / os_unfair_lock)            │   │
│  │  processRenderAudio(alignedSystemFrame)  // FIRST                 │   │
│  │  processCaptureAudio(micFrame) → cleanedAudio  // THEN            │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                              │                                           │
│                              ▼                                           │
│                       Cleaned Audio                                      │
└─────────────────────────────────────────────────────────────────────────┘
```

### What Swift Handles (Coarse Alignment)

1. **Offset calculation** during warmup (~1 second, 12 buffers)
2. **System audio ring buffer** (500ms capacity, indexed by sample count)
3. **Mic audio ring buffer** (for alignment lookup)
4. **Frame alignment** - `findMatchingSystemAudio()` uses offset to pair frames
5. **Gap detection** (SCK drops buffers; fill with silence)
6. **Offset validation** (Lesson 7 - verify offset matches reality)
7. **Bounds check fallback** (pass-through if target exceeds available)

### What WebRTC Handles (Fine-Grained)

1. Fine-grained delay tracking (±50ms drift AFTER coarse alignment)
2. Double-talk detection
3. Echo cancellation (25-35 dB ERLE)
4. Non-linear processing

### WebRTC Library Source

- **Library**: FreeDesktop webrtc-audio-processing v2.x
- **Repository**: https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing
- **License**: BSD-3-Clause (compatible with Muesli's MIT license)
- **Build**: `./scripts/build-webrtc-aec.sh` creates XCFramework for arm64/x86_64
- **Note**: Earlier documentation referenced v1.3, which had an external delay estimator API. That API is not available in v2.x; AEC3 uses internal delay estimation only (see [External Delay Estimator Status](#external-delay-estimator-status)).

### Performance Characteristics

| Metric | WebRTC AEC3 | NLMS (Legacy) |
|--------|-------------|---------------|
| **ERLE** | 25-35 dB | 10-15 dB |
| **CPU** | <5% overhead | <2% overhead |
| **Memory** | ~300-400 KB | ~60 KB |
| **Latency** | <10ms | <10ms |
| **DTD** | Built-in | None |
| **NLP** | Built-in | None |

### Implementation Selection

Users can select the AEC implementation via preferences (default: WebRTC):

```swift
// In PreferencesManager
var aecImplementationType: AECImplementation  // .webrtc or .nlms

// Factory creates the appropriate service
let service = EchoCancellationServiceFactory.create(
    implementation: preferencesManager.aecImplementationType
)
```

If WebRTC initialization fails, the factory automatically falls back to NLMS.

### Diagnostic Logging

WebRTC-specific log messages:

| Message | Meaning |
|---------|---------|
| `WEBRTC_INIT_SUCCESS` | AEC3 initialized successfully |
| `WEBRTC_INIT_FAILED` | Initialization error (check error details) |
| `WEBRTC_OFFSET` | Calculated offset in samples and milliseconds |
| `WEBRTC_OFFSET_CORRECTION` | Offset validation corrected a drifting offset |
| `WEBRTC_GAP` | Gap detected, filled with silence |
| `WEBRTC_RENDER_FAILED` | Render frame processing failed |
| `WEBRTC_CAPTURE_FAILED` | Capture frame processing failed |
| `WEBRTC_RESET` | Service reset, includes ERLE and delay stats |
| `AEC_FACTORY` | Factory created WebRTC or NLMS service |
| `AEC_FACTORY_FALLBACK` | WebRTC failed, using NLMS fallback |

> **Note on `AEC_FACTORY_FALLBACK`**: The NLMS fallback is intentional and the fallback implementation file (`EchoCancellationService.swift`) is still present in the codebase. If WebRTC AEC3 initialization fails (e.g., missing framework, unsupported platform), the factory automatically falls back to the NLMS implementation to ensure echo cancellation remains available.

### Troubleshooting WebRTC Issues

1. **Stub mode warning**: If you see `[WebRTCAEC] Initialized in STUB mode`, the WebRTC library isn't built. Run `./scripts/build-webrtc-aec.sh` to build it.

2. **Poor echo cancellation**: Check `WEBRTC_OFFSET` logs. If offset is unstable or very large (>500ms), there may be an issue with stream timing.

3. **Audio dropouts**: Check for `WEBRTC_GAP` messages. Frequent gaps indicate ScreenCaptureKit buffer issues.

4. **Fallback to NLMS**: If `AEC_FACTORY_FALLBACK` appears, WebRTC initialization failed. Check `WEBRTC_INIT_FAILED` for the error.

---

## 2026-01-27 Investigation: WebRTC AEC3 Not Converging

This section summarizes the latest quantitative findings from the AEC3 regression investigation (builds around commit `35455b6`). The key symptom is persistent low ERLE (~0.2 dB) and delay estimate stuck at 0 ms, even when system audio is present and transcription is accurate.

### Key Quantitative Observations (Logs)

From diagnostic logs recorded during the 04:02, 04:08, and 04:11 sessions:

1. **Mic starts after system, but with material delay**
   - `MIC_FIRST_BUFFER` occurs ~200-316 ms after `SYSTEM_FIRST_BUFFER`.
   - Example: `deltaFromSystemMs=209.5` to `316.4`.

2. **Render stays ahead of capture**
   - `WEBRTC_SYNC_STATUS` shows `sampleDelta=100-300 ms` (e.g. 5760 samples = 120 ms, 14400 samples = 300 ms).
   - `sysAvail=24000 (500.0 ms)` consistently indicates the system ring buffer stays full, while `micAvail=0`.

3. **System extraction is not consistently silent**
   - `SYS_EXTRACT_RMS` ranges from about `-16 dB` to `-35 dB` during steady playback.
   - Intermittent `-100 dB` samples occur early or during quiet segments.

4. **Render RMS matches system extraction**
   - `WEBRTC_RENDER_RMS` is `-100 dB` for the first few hundred frames, then tracks system audio levels (e.g. `-12 dB` to `-35 dB`).
   - This confirms render audio is reaching AEC and is not permanently zero.

5. **AEC still does not converge**
   - `WEBRTC_CAPTURE_SENT` stays near `ERLE=0.2 dB`, `delay=0 ms` across runs.
   - Mic input levels are typically `-48 dB` to `-53 dB`.

### Interpretation

The investigation rules out a permanently silent render reference. The render reference is present and at reasonable levels, but AEC3 still does not estimate delay or converge. The persistent render lead (100-300 ms, with system buffer held at 500 ms available) suggests AEC3 may need explicit stream delay or tighter render lead control. This aligns with the hypothesis that AEC3 is seeing a large, steady lead without a proper delay model.

### Why Transcription Can Still Work

Transcription uses the same system audio path (ScreenCaptureKit -> resample -> WhisperKit), so transcripts can be accurate while AEC fails. AEC depends on time-aligned correlation between render and capture; transcription does not.

### Next Diagnostic Step

Correlation instrumentation (`AEC_CORR`) is now added to measure the normalized correlation between the latest render frame and the current capture frame, along with render/mic dB and lead. This will confirm whether the capture contains echo correlated with the render reference at the observed delay.

---

## 2026-01-27 Follow-up: External Delay Estimator Unsupported

This follow-up captures the findings from the 04:50 run after adding aligned render feed and explicit delay hints.

### Key Findings

1. **External delay estimator is unavailable in the current WebRTC XCFramework**
   - Log shows `WEBRTC_AEC3_CONFIG: externalDelayEstimator=false` at app launch.
   - The bundled headers lack `EchoCanceller3Config::identifier`, so `webrtc::Config::Set(...)` cannot be used.
   - As a result, `set_stream_delay_ms` is not honored by AEC3 in this build.

2. **Aligned render feed removes the timing signal**
   - Aligned render is injected at capture time (expected lag), so render/capture arrive together.
   - With internal delay estimation only, AEC3 sees ~0 ms delay and does not converge.
   - Observed in logs: `WEBRTC_CAPTURE_SENT` delay remains `0 ms` and ERLE stays ~`0.2 dB`.

3. **Render energy is present but cancellation does not improve**
   - `WEBRTC_RENDER_ALIGNED` shows render levels (e.g., `-15 dB` to `-47 dB`) once playback is active.
   - `AEC_CORR_ENERGY` frequently reports `expectedValid=true`, confirming render is present at the expected lag.
   - Despite this, ERLE remains flat because delay estimation is disabled or starved of timing.

### Interpretation

The current WebRTC XCFramework cannot enable the external delay estimator, so the only usable delay signal is the natural arrival timing of render vs capture frames. The aligned-feed mode removes that signal and therefore cannot converge in this build.

### Validation Plan (Internal Estimator in Intended Mode)

1. **Revert to arrival-timed render feed** (use `storeSystemAudio → processRenderFrame` only).
2. **Confirm internal estimator is active**:
   - `WEBRTC_AEC3_CONFIG: externalDelayEstimator=false` (expected for current framework).
3. **Check convergence metrics**:
   - `WEBRTC_CAPTURE_SENT` delay should move away from 0 ms.
   - ERLE should increase above ~10 dB during steady playback.
4. **If still flat**:
   - Upgrade the WebRTC XCFramework (headers + binaries) to support external delay.
   - Or add a small fixed capture delay buffer to stabilize render lead without external delay.

---

## Stream Synchronization (Legacy ScreenCaptureKit)

**Note**: This section describes the legacy ScreenCaptureKit synchronization approach. For the Core Audio taps architecture, see the [Audio Synchronizer](#audio-synchronizer) section above.

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

### Post-Warmup Offset Validation (2026-01-25 Fix)

The warmup period can capture transient startup behavior rather than steady-state timing. To catch this, we validate the calculated offset against actual sample counts immediately after warmup:

```swift
// After offset calculation, before setting streamsSynchronized = true
let actualDelta = totalSystemSamples - totalMicSamples
let mismatch = abs(actualDelta - deliveryOffsetSamples)
let mismatchThreshold: Int64 = 2400  // 50ms at 48kHz (2x typical jitter)

if mismatch > mismatchThreshold {
    // Offset doesn't match reality - use actual sample difference
    var correctedOffset = actualDelta
    correctedOffset = max(-24000, min(24000, correctedOffset))  // Clamp ±500ms
    deliveryOffsetSamples = correctedOffset
}
```

**Threshold Selection**: 50ms (2400 samples) is 2x typical steady-state jitter (10-30ms), avoiding false positives while catching genuine warmup artifacts.

### Bounds Check Fallback

If `targetSysIndex` exceeds available system samples (due to offset issues or timing anomalies), we fall back to pass-through rather than failing:

```swift
if targetSysIndex > state.totalSystemSamples {
    boundsCheckFallbackCount += 1
    // Log first occurrence and every 100th thereafter
    return (microphoneSamples, nil)  // Pass-through preserves user's voice
}
```

**Why pass-through**: Preserves user's voice even if echo is present. Silence would lose data permanently. Echo in output is audible evidence for debugging.

### Periodic Offset Monitoring

Every 60 seconds (2880 buffers at ~20ms/buffer), we log the offset stability:

```swift
let actualDelta = totalSystemSamples - totalMicSamples
let offsetError = actualDelta - deliveryOffsetSamples
// Log: OFFSET_CHECK: claimed=X, actual=Y, mismatch=Z samples
```

This helps detect drift during long recordings without impacting performance.

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
| `OFFSET_VALIDATION: mismatch=X samples, correcting` | Warmup offset corrected to match reality |
| `BOUNDS_FALLBACK: target=X > totalSys=Y` | Pass-through used when target exceeds available |
| `OFFSET_CHECK: claimed=X, actual=Y, mismatch=Z` | Periodic (60s) offset stability check |

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
| `OFFSET_VALIDATION: mismatch=X samples, correcting` | Warmup offset didn't match reality, corrected |
| `BOUNDS_FALLBACK: target=X > totalSys=Y, occurred N times` | Target index exceeded available samples, pass-through used |
| `OFFSET_CHECK: claimed=X, actual=Y, mismatch=Z` | Periodic (60s) offset stability check |

### Healthy Log Pattern

```
[AEC] SYNC_OFFSET: delivery_offset=14976 samples (312.0ms), mic_ahead, sync_after=1.042s
[AEC] MATCH: 95/100 (95.0%)
[AEC] MATCH: 195/200 (97.5%)
[AEC] MATCH: 297/300 (99.0%)
```

### Unhealthy Log Pattern (Immediate Sync)

```
[AEC] SYNC: streams synchronized in 0.031s    ← OLD: immediate sync (bad)
[AEC] MATCH: 2/100 (2.0%)                      ← Near 0% = streams misaligned
[AEC] MATCH: 2/200 (1.0%)
```

### Unhealthy Log Pattern (Offset Mismatch - 2026-01-25)

```
[AEC] SYNC_OFFSET: delivery_offset=-19217 samples (-400.4ms), mic_behind
[AEC] SYNC_STATE: totalSys=53760, totalMic=52800, offset=-19217, ...
[AEC] INDEX: micStart=52800, acoustic=2400, offset=-19217, target=69617, sysSamples=53760
[AEC] LOOKUP: target=69617, buffers=0-53760, count=56     ← target > max buffer!
[AEC] MATCH: 0/100 (0.0%)                                  ← 0% = target unreachable
```

**Key diagnostic**: Compare `sysSamples - micSamples` (actual difference: 960) vs `abs(offset)` (claimed difference: 19217). Large mismatch indicates offset doesn't reflect reality.

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

### 5. Target Index Exceeds Buffer Range (2026-01-25)

**Symptom**: 0% match rate with logs showing:
```
INDEX: micStart=X, acoustic=Y, offset=Z, target=T, sysSamples=S
```
Where `target > sysSamples`.

**Example**:
```
SYNC_OFFSET: delivery_offset=-19217 samples (-400.4ms), mic_behind
INDEX: micStart=52800, acoustic=2400, offset=-19217, target=69617, sysSamples=53760
LOOKUP: target=69617, buffers=0-53760, count=56
MATCH: 0/100 (0.0%)
```

**Diagnosis**: The calculated target (69617) exceeds available system samples (53760).

**Causes**:
- Large negative offset calculated during warmup doesn't match steady-state behavior
- Warmup captured transient startup timing, not continuous delivery pattern
- Offset says system is "ahead" by 400ms, but actual sample counts differ by only 20ms

**Investigation**:
1. Check if `sysSamples - micSamples` matches `abs(offset)` (they should be close)
2. If mismatch is large (>10%), offset measurement may be unreliable
3. Look for signs of startup transient: large offset but similar sample counts

**Workarounds** (pending permanent fix):
- Add bounds check to return pass-through when target exceeds available samples
- Implement offset validation against actual sample counts after warmup
- Consider longer warmup or dynamic offset recalibration

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

### Lesson 6: targetSysIndex Sign Convention (2026-01-25)

**Problem**: The `targetSysIndex` calculation was adding the delivery offset when it should subtract:

```swift
// WRONG (original)
let targetSysIndex = micStartIndex - acousticDelaySamples + deliveryOffsetSamples

// CORRECT (fixed)
let targetSysIndex = micStartIndex - acousticDelaySamples - deliveryOffsetSamples
```

**Reasoning**:
- `deliveryOffsetSamples = avgSysTime - avgMicTime`
- Positive offset = mic arrived first = mic index is "ahead" for same wall-clock moment
- When mic is ahead, we need to look at a LOWER system index (subtract positive)
- When mic is behind (negative offset), we need a HIGHER system index (subtract negative = add)

**The math**:
- If mic is ahead by N samples, at mic index M, the corresponding system audio is at M - N
- Formula: `targetSysIndex = micStartIndex - acousticDelay - offset`

**Prevention**: Always reason through both positive and negative offset cases when writing sync formulas.

### Lesson 7: Warmup Offset May Not Match Steady-State (2026-01-25 - FIXED)

**Problem**: During testing, observed 0% match rate despite correct sign fix. The logs revealed:

```
SYNC_OFFSET: delivery_offset=-19217 samples (-400.4ms), mic_behind
INDEX: micStart=52800, acoustic=2400, offset=-19217, target=69617, sysSamples=53760
MATCH: 0/300 (0.0%)
```

The target (69617) exceeds available system samples (53760).

**Root Cause Analysis**:

The warmup offset measurement captured transient startup behavior, not steady-state:
- **Measured offset**: -19217 samples (-400ms) suggesting system is ~400ms ahead
- **Actual difference**: `sysSamples - micSamples = 53760 - 52800 = 960` samples (~20ms)

The warmup period (first 12 buffers, ~1 second) captured timing differences that don't persist in steady state. Possible causes:
1. AVAudioEngine starts delivering before ScreenCaptureKit is fully initialized
2. ScreenCaptureKit has variable startup latency that normalizes after warmup
3. Initial buffer scheduling jitter is much higher than steady-state jitter

**Implications**:

With a large offset that doesn't match reality:
- `targetSysIndex = micStart - acoustic - offset`
- When offset is large negative (-19217), subtracting it ADDS, pushing target far ahead
- Target ends up beyond available system samples → 0% match rate

**Fix Implemented (2026-01-25)**:

1. **Post-Warmup Offset Validation**: Immediately after warmup completes, validate the calculated offset against actual sample counts:
   ```swift
   let actualDelta = totalSystemSamples - totalMicSamples
   let mismatch = abs(actualDelta - deliveryOffsetSamples)
   if mismatch > 2400 {  // 50ms threshold (2x typical jitter)
       deliveryOffsetSamples = max(-24000, min(24000, actualDelta))  // Correct and clamp
   }
   ```

2. **Bounds Check Fallback**: If `targetSysIndex > totalSystemSamples`, fall back to pass-through:
   ```swift
   if targetSysIndex > state.totalSystemSamples {
       boundsCheckFallbackCount += 1
       return (microphoneSamples, nil)  // Pass-through preserves user's voice
   }
   ```

3. **Periodic Offset Monitoring**: Every 60 seconds, log offset stability to detect drift during long recordings.

**Status**: Fixed. Offset validation catches warmup artifacts, bounds check provides safety net, periodic monitoring enables drift detection.

---

## Implementation Status

### Completed (as of January 2026)

| Phase | Component | Status | Notes |
|-------|-----------|--------|-------|
| Phase 1 | Core Audio Tap Infrastructure | ✅ Complete | `CoreAudioTapManager`, `AggregateDeviceManager`, self-tests |
| Phase 2 | Synchronizer | ✅ Complete | `AudioSynchronizer`, `TapCaptureRing`, `MicCaptureRing`, `CoarseDelayController`, `DriftTracker` |
| Phase 3 | AEC Pipeline | ✅ Complete | `WebRTCAECBridge.mm` simplified for frame processing |
| Phase 4 | IOProc RT-Safety | ✅ Complete | RT-safe callback in `CoreAudioTapManager` |
| Phase 5 | Permissions | ⚠️ Partial | `PermissionManager` updated, but must verify `NSAudioCaptureUsageDescription` and Screen & System Audio Recording state |
| Phase 6 | Remove Old Code | ❌ Incomplete | Legacy files NOT removed (see below) |
| Phase 7 | Testing | ✅ Complete | Unit tests, integration tests, manual testing |

### Phase 6 Cleanup - NOT YET COMPLETED

The following legacy files were scheduled for removal but still exist:

| File | Status | Action Required |
|------|--------|-----------------|
| `AudioCaptureService.swift` | ✅ DELETED | Removed; Core Audio taps replaced ScreenCaptureKit capture |
| `EchoCancellationService.swift` | Still exists | Delete (NLMS legacy) |
| `EchoCancellationServiceWebRTC.swift` | Still exists | Evaluate if needed or superseded |
| `AudioRingBuffer.swift` | Still exists | Delete (replaced by TapCaptureRing/MicCaptureRing) |

**Recommendation**: `AudioCaptureService.swift` has been deleted (Core Audio taps replaced ScreenCaptureKit). Remove `EchoCancellationService.swift` and `AudioRingBuffer.swift` which are also superseded.

### New Files Created (Not in Original Plan)

| File | Purpose |
|------|---------|
| `TapAudioCaptureService.swift` | Service wrapper for Core Audio tap capture |
| `AECProcessor.swift` | AEC processing pipeline (render-to-capture frame processing) |
| `AudioWorker.swift` | Dedicated worker thread for audio processing |

### Plan vs. Reality Corrections

| Plan Statement | Reality | Impact |
|----------------|---------|--------|
| "macOS 26 Tahoe+ only" | Core Audio taps available in macOS 14.2+ | Lower minimum version, broader compatibility |
| "`NSAudioCaptureUsageDescription`" | Required Info.plist key for system audio capture | Ensure Info.plist contains it and permission UX points to Screen & System Audio Recording |
| "DelayAgnostic + ExtendedFilter" | Not explicit options in v2.x API | Config is just `echo_canceller.enabled` |
| "External delay estimator for coarse alignment" | Not available in bundled WebRTC | Must rely on internal delay estimation |

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

**Status**: ✅ IMPLEMENTED (January 2026)  
**Impact**: High - production-quality AEC  
**Effort**: High

WebRTC's AEC3 is now the default implementation, providing:
- Built-in delay estimation
- Double-talk detection
- Non-linear processing
- 25-35 dB ERLE (vs 10-15 dB with NLMS)

See [WebRTC AEC3 Integration](#webrtc-aec3-integration) section for implementation details.

**Files added**:
- `Muesli/Services/EchoCancellationServiceWebRTC.swift` - Swift hybrid sync implementation
- `Muesli/Services/AudioRingBuffer.swift` - Real-time safe ring buffer
- `Muesli/Services/WebRTCAEC/WebRTCAECBridge.h/.mm` - ObjC++ bridge to WebRTC
- `scripts/build-webrtc-aec.sh` - Build script for WebRTC XCFramework

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
| webrtc-audio-processing (FreeDesktop) | https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing |
| Apple Core Audio Taps | https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps |
| Apple ScreenCaptureKit | https://developer.apple.com/documentation/screencapturekit |
| Apple AVAudioEngine | https://developer.apple.com/documentation/avfaudio/avaudioengine |
| AudioCap (sample code) | https://github.com/insidegui/audiocap |
| VOCAL Technologies AEC | https://vocal.com/echo-cancellation/ (good tutorials) |

### Related Muesli Documentation

| Document | Content |
|----------|---------|
| `spec/audio_pipeline.md` | Overall audio architecture, sample rates, file formats |
| `AGENTS.md` | Build commands, thread safety requirements |
| `AudioConfiguration.swift` | All AEC parameters with documentation |
| `CoreAudioTapManager.swift` | Tap lifecycle, IOProc callback, self-tests |
| `AggregateDeviceManager.swift` | Tap-only aggregate device creation |
| `AudioSynchronizer.swift` | Sample-index pairing, state machine |
| `CoarseDelayController.swift` | Hysteresis + slew-limited delay control |
| `DriftTracker.swift` | Clock drift estimation + adaptive resampler |
| `WebRTCAECBridge.mm` | WebRTC AEC3 v2.x ObjC++ bridge |

---

## Best Practices

### System Audio Permission Model

- Use a **tap-probe at session start** to determine system audio permission status. Do not call `CGPreflightScreenCaptureAccess()` as a preflight check for Core Audio taps — that API is specific to ScreenCaptureKit.
- The result of the tap-probe is **cached in UserDefaults** so subsequent sessions can skip the probe if permission was previously granted.
- If the tap-probe fails (silence detected), degrade gracefully to mic-only mode and show actionable UI guidance.

### Real-Time Audio Callback Constraints

The IOProc callback (`CoreAudioTapManager.handleIOProc`) runs on a real-time audio thread. Violating RT constraints causes audio glitches, dropouts, or priority inversion. The following are **strictly prohibited** inside the IOProc:

- **No heap allocation** (`malloc`, `new`, Swift Array/Dictionary growth)
- **No Objective-C messaging** (no ARC retain/release, no `@objc` dispatch)
- **No locks** (`os_unfair_lock`, `pthread_mutex`, `NSLock`) — use only lock-free ring buffers
- **No syscalls** (no file I/O, no network, no logging)

All format conversion, framing, AEC processing, and logging must be deferred to a dedicated audio worker thread.

### WhisperKit Audio Format Requirements

WhisperKit requires **16 kHz mono** audio for transcription. Both system audio (Core Audio tap) and microphone (AVAudioEngine) capture at **48 kHz**. Always resample before feeding to WhisperKit:

```swift
// System: 48kHz stereo → 16kHz mono
resampleToWhisperFormat(buffer, sourceSampleRate: 48000, sourceChannels: 2)
// Mic: 48kHz mono → 16kHz mono
resampleToWhisperFormat(buffer, sourceSampleRate: 48000, sourceChannels: 1)
```

Failing to resample results in gibberish transcription output.

### macOS Version Requirements

`AudioHardwareCreateProcessTap` and `CATapDescription` require **macOS 14.2+** (Sonoma). The app deployment target is **macOS 26.0** (`MACOSX_DEPLOYMENT_TARGET = 26.0`), which satisfies this requirement. Earlier macOS versions do not have the Core Audio tap APIs and cannot capture system audio using this architecture.

---

## Document History

| Date | Change | Author |
|------|--------|--------|
| 2026-01-24 | Initial creation based on stream offset fix debugging session | Agent |
| 2026-01-24 | Added: Parameter tuning guide, testing metrics (ERLE/ERL/MOS), expanded DTD section with simple approaches, VSS-NLMS discussion, standards references | Agent |
| 2026-01-25 | Added: Buffer Gap Handling and Continuity section documenting wall-clock-based gap detection with silence fill per AEC clock drift fix plan | Agent |
| 2026-01-25 | Added: Lesson 6 (targetSysIndex sign fix), Lesson 7 (warmup offset vs steady-state mismatch - active investigation), Failure Mode 5 (target exceeds buffer range) | Agent |
| 2026-01-25 | Implemented: Post-warmup offset validation, bounds check fallback, periodic offset monitoring. Updated Lesson 7 status to FIXED. Added new diagnostic log messages. | Agent |
| 2026-01-26 | **WebRTC AEC3 Integration**: Added hybrid synchronization architecture with WebRTC AEC3 as default implementation. Includes: EchoCancellationServiceWebRTC (Swift), AudioRingBuffer, WebRTCAECBridge (ObjC++), factory pattern for implementation selection. NLMS preserved as fallback. | Agent |
| 2026-01-27 | Added: Quantitative analysis of AEC3 non-convergence, render/mic RMS findings, and correlation instrumentation context. | Agent |
| 2026-01-31 | **Major Update: Core Audio Taps Architecture**: Comprehensive documentation of the Core Audio taps implementation. Key corrections: (1) macOS 14.2+ support, not "macOS 26 only"; (2) NSAudioCaptureUsageDescription required for system audio capture; (3) WebRTC v2.x API doesn't have DelayAgnostic/ExtendedFilter as explicit options; (4) External delay estimator not available. Added: AudioSynchronizer section, Implementation Status with Phase 6 cleanup pending, Plan vs Reality corrections. | Agent |
| 2026-01-31 | **Core Audio Tap Investigation (Resolved)**: Earlier investigation into zero samples from `AudioHardwareCreateProcessTap` was due to a self-test flaw (beep played from own process, which was in the exclusion list) and Sequoia-era bugs fixed in macOS 15.2+. Core Audio taps work correctly on macOS 26. Investigation section removed 2026-02-18. | Agent |
