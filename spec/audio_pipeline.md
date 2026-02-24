# Audio Pipeline Specification

This document specifies how Muesli captures, processes, and transcribes audio from meetings.

## Overview

The audio pipeline handles two parallel streams:
1. **System Audio**: Captured from meeting apps (Zoom, Teams, Meet) via Core Audio taps (`AudioHardwareCreateProcessTap`)
2. **Microphone Audio**: Captured from the user's selected microphone via AVAudioEngine (managed by TapAudioCaptureService)

Both streams are simultaneously:
- Written to disk as CAF files (for playback/reprocessing)
- Resampled and fed to WhisperKit (for real-time transcription)

## Architecture

### Core Audio Taps Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                 Output Tap (Core Audio)                      │
│     (default output mix; excludes Muesli process)            │
│   Tap-only aggregate device (NO mic subdevice)               │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
                    TapCaptureRing (render)

┌─────────────────────────────────────────────────────────────┐
│                 Mic Capture (AVAudioEngine)                  │
│        (supports user device selection)                      │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
                    MicCaptureRing (capture)

                 ┌─────────────────────────────────┐
                 │          AudioSynchronizer       │
                 │  - sample-index timeline         │
                 │  - bounded jitter buffers        │
                 │  - discontinuity detection       │
                 │  - coarse delay controller       │
                 │  - drift tracker + resampler     │
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

Key advantages of Core Audio taps:
- **Single clock domain**: Tap and mic use same sample rate clock
- **Sample-index alignment**: Precise pairing without timestamp drift
- **Process exclusion**: True exclusion of Muesli's own audio output
- **Lower latency**: Direct device access vs ScreenCaptureKit buffering

> **Note:** See the Core Audio Taps Architecture diagram above for the current pipeline layout.

## Sample Rate Reference

| Stage | System Audio | Microphone Audio |
|-------|-------------|-----------------|
| Capture | 48kHz stereo Float32 | 48kHz mono Float32 |
| File Output | 48kHz stereo Float32 | 48kHz stereo Float32* |
| Transcription | 16kHz mono Float32 | 16kHz mono Float32 |

*Microphone is captured mono but written stereo for format consistency.

**Critical**: WhisperKit requires 16kHz mono audio. Feeding 48kHz audio produces gibberish output.

## Key Configuration

All audio constants are centralized in `AudioConfiguration.swift`:

```swift
enum AudioConfiguration {
    // Sample rates
    static let whisperSampleRate: Int = 16000      // WhisperKit requirement
    static let captureSampleRate: Int = 48000      // Core Audio tap / AVAudioEngine default
    static let microphoneSampleRate: Int = 48000   // AVAudioEngine default
    
    // Transcription
    static let transcriptionChunkDuration: TimeInterval = 5.0   // Process in 5-second windows
    static let transcriptionOverlapDuration: TimeInterval = 1.5 // Overlap for continuity
    
    // Buffering
    static let maxBufferSamples: Int = 480_000     // 30 seconds at 16kHz
    static let bufferTimeoutSeconds: TimeInterval = 300.0  // 5-minute safety net (memory bounded by maxBufferSamples)
    
    // Voice activity detection
    static let vadThreshold: Float = 0.01         // RMS threshold (~-40dB)
}
```

## Why AVAudioEngine for Microphone?

ScreenCaptureKit's `captureMicrophone` API (macOS 15+) has two issues:

1. **No device selection**: Always uses system default microphone, ignoring user preference
2. **Reliability**: Observed to return all-zero samples in some configurations

TapAudioCaptureService manages mic via AVAudioEngine, providing:
- Explicit device selection via `AudioObjectSetPropertyData`
- Consistent Float32 sample format
- Integration with the Core Audio tap pipeline for synchronized capture

## File Output

### Format Specification

Both audio files use Core Audio Format (CAF) with Linear PCM:

| Property | Value |
|----------|-------|
| Format | CAF (Core Audio Format) |
| Codec | Linear PCM (uncompressed) |
| Sample Rate | 48,000 Hz |
| Bit Depth | 32-bit |
| Sample Type | Float (IEEE 754) |
| Channels | 2 (stereo) |
| Byte Order | Little-endian |

### Why Separate Files?

CAF doesn't support multiple audio tracks. Separating system and microphone audio:
- Allows independent post-processing
- Enables mixing at different levels
- Supports reprocessing with different speaker assignments

### Buffer Queue Management

`FileOutputService` uses a buffer queue to handle backpressure:

```swift
// When AVAssetWriterInput.isReadyForMoreMediaData is false,
// buffers are queued instead of dropped
private var systemBufferQueue: [CMSampleBuffer] = []
private var micBufferQueue: [CMSampleBuffer] = []

// Maximum queue size before dropping oldest buffers
static let maxQueuedBuffers: Int = 10  // ~200ms of audio
```

## Transcription Pipeline

### Resampling

`TranscriptionService.resampleToWhisperFormat()` converts capture audio to WhisperKit format:

```swift
// System: 48kHz stereo → 16kHz mono
resampleToWhisperFormat(buffer, sourceSampleRate: 48000, sourceChannels: 2)

// Microphone: 48kHz mono → 16kHz mono
resampleToWhisperFormat(buffer, sourceSampleRate: 48000, sourceChannels: 1)
```

### Chunking Strategy

Audio is processed in overlapping chunks for better transcription quality:

```
Time:    0s    5s    10s   15s   20s
         |─────|─────|─────|─────|
Chunk 1: |████████|
Chunk 2:      |████████|
Chunk 3:           |████████|
              ↑
         1.5s overlap
```

- **Chunk duration**: 5 seconds (configurable)
- **Overlap**: 1.5 seconds
- **Minimum samples**: 80,000 (5s × 16kHz)

### Audio Buffering During Model Load

`TranscriptionCoordinator` buffers audio while the WhisperKit model initializes:

1. Recording starts immediately (audio saved to disk)
2. Model loading begins asynchronously
3. Audio samples are buffered (up to 30 seconds)
4. Once model is ready, buffered audio is processed
5. If model takes >30 seconds, timeout triggers

## Echo Cancellation (AEC)

The Echo Cancellation Service removes echo from microphone audio when the user's speakers play system audio (e.g., meeting participants' voices).

### AEC Warmup Period

The Echo Cancellation Service requires a warmup period at the start of each recording:

1. **First ~12 buffers from each stream:** Both audio streams deliver samples while delivery offset is calculated
2. **During warmup:** Microphone audio passes through unprocessed (no echo cancellation)
3. **After warmup:** AEC activates with correct stream alignment

**Configuration:** `kBuffersToAverage = 12` (defined in `EchoCancellationServiceWebRTC.SyncState`)

**Expected warmup duration:**
- Typical buffer: ~4096 samples at 48kHz (~85ms per buffer)
- Conservative estimate: 12 buffers x 85ms = ~1.0 second
- Practical observation: ~1 second (buffers interleave rapidly from both streams)
- Timeout fallback: 5 seconds (forces pass-through mode if sync fails)

### Why Warmup is Necessary

The warmup period exists because:
1. **NLMS algorithm needs reference data:** Echo prediction requires a history of system audio samples
2. **Stream timing must be measured:** Delivery offset between system audio and microphone must be calculated
3. **Sample-count synchronization:** Unlike timestamp-based sync, sample-count alignment needs to observe buffer delivery patterns

### User Impact

The first ~1 second of recording may have echo. This is acceptable for meeting recordings where the first few seconds are typically introductions, silence, or "Can you hear me?" exchanges.

### Fallback Behavior

If sample rate resampling fails (mic not at 48kHz and can't be resampled), AEC is **disabled for the entire recording session**. This ensures:
- Audio is still recorded correctly (no data loss)
- No corrupt AEC output from mismatched sample rates
- User is warned via UI notification

## Thread Safety

### CMSampleBuffer Handling

`CMSampleBuffer` is not `Sendable`. The pipeline uses `OSAllocatedUnfairLock` for thread-safe access:

```swift
// DO NOT use actor isolation for high-frequency audio callbacks
// OSAllocatedUnfairLock provides lower latency

private let bufferState = OSAllocatedUnfairLock(initialState: BufferState())

func handleBuffer(_ buffer: CMSampleBuffer) {
    bufferState.withLock { state in
        state.pendingBuffers.append(buffer)
    }
}
```

### Audio Callback Context

Audio callbacks from CoreAudioTapManager IOProc and AVAudioEngine tap run on real-time priority threads:

- **Never block** in callback handlers (no heap allocation, no Objective-C messaging, no locks)
- **Lock-free ring buffer handoff**: IOProc writes samples into `TapCaptureRing`/`MicCaptureRing`; a separate Swift worker thread (`AudioWorker`) reads from the rings and dispatches to downstream consumers
- **Queue work** for async processing if needed

## Debugging Guide

### Transcription Outputs Gibberish

**Check sample rates first!** This is the most common issue.

1. Verify capture sample rate matches expected (48kHz)
2. Verify resampling is happening (48kHz → 16kHz)
3. Check channel count conversion (stereo → mono)

### No Microphone Audio

1. Check microphone permission granted
2. Verify AVAudioEngine started successfully in `TapAudioCaptureService`
3. Check selected device ID exists and is valid
4. Look for "Warning: Microphone capture failed to start" in logs
5. Verify `MicCaptureRing` is receiving samples (check AudioWorker drain loop)

### Audio Gaps or Dropouts

1. Check `FileOutputService` buffer queue warnings
2. Verify `AVAssetWriterInput.isReadyForMoreMediaData` is true most of the time
3. Look for "WARNING: Dropping N audio buffers" messages
4. Consider reducing other CPU load during recording

### Model Loading Timeout

1. Check if model exists at expected path
2. Verify model is not corrupted (check `config.json` exists)
3. Check available memory (large models need ~2GB)
4. Look for fallback model switch notifications

## Transcript Reprocessing

The reprocess feature allows users to re-transcribe existing audio files with a different WhisperKit model.

### Reprocessing Flow

```
User clicks "Reprocess" → ViewModel.reprocessTranscript()
                                    │
                                    ▼
                      TranscriptionCoordinator.reprocessTranscript()
                                    │
                      ┌─────────────┴─────────────┐
                      │                           │
                      ▼                           ▼
              Validate model             Load audio files
              Initialize WhisperKit      (audio.caf, microphone.caf[AEC-processed], [raw_microphone.caf optional])
                      │                           │
                      └─────────────┬─────────────┘
                                    │
                                    ▼
                      TranscriptionService.transcribePostProcessing()
                                    │
                                    ▼
                      loadAudioFile() for each file
                          │
                          ▼
                      AVAudioConverter: 48kHz → 16kHz
                          │
                          ▼
                      WhisperKit.transcribe()
                          │
                          ▼
                      Collect segments via handler
                                    │
                                    ▼
                      Convert to TranscriptBlocks (~50 words max)
                                    │
                                    ▼
                      Update meeting.transcriptBlocks
                      Update meeting.transcript
                      Save to disk via FileOutputService
```

### Critical Implementation Details

**1. AVAudioConverter Status Handling**

When loading audio files for reprocessing, `AVAudioConverter` returns different status codes:

| Status | Raw Value | Meaning |
|--------|-----------|---------|
| `.haveData` | 0 | Output has data, more input may be available |
| `.inputRanDry` | 1 | **Input exhausted, BUT output has valid data** |
| `.endOfStream` | 2 | End of stream |
| `.error` | 3 | Error occurred |

**WARNING**: When reading an entire file at once (not streaming), the converter ALWAYS returns `.inputRanDry` because all input is consumed. This is a **successful** conversion!

```swift
// CORRECT: Accept both statuses
let isValidStatus = (status == .haveData || status == .inputRanDry)
guard isValidStatus, let floatChannelData = outputBuffer.floatChannelData else {
    return nil
}

// WRONG: Only checking .haveData rejects valid conversions!
// guard status == .haveData, ... // DON'T DO THIS
```

**2. Transcript Must Be Saved**

After transcription, the results MUST be:
1. Converted to `TranscriptBlock` objects (chunked to ~50 words)
2. Stored in `meeting.transcriptBlocks` and `meeting.transcript`
3. Saved to disk via `FileOutputService.saveTranscriptBlocks()`

If any step is missing, the UI won't update.

**3. Block Chunking**

Long transcription segments are split into multiple `TranscriptBlock` objects:
- Maximum ~50 words per block for readability
- Timestamps are approximated based on word position
- Speaker attribution is preserved across chunks

### Debugging Reprocessing Issues

| Symptom | Likely Cause | Solution |
|---------|--------------|----------|
| Button grays out but transcript unchanged | Segments not saved (check for TODO) | Implement saving logic |
| Very fast completion (no transcription) | Audio load failed | Check AVAudioConverter status handling |
| Empty transcript after reprocess | WhisperKit returned empty results | Check audio file integrity |
| App hangs during reprocess | Model initialization stuck | Check model path and memory |

## Key Files

| File | Responsibility |
|------|----------------|
| `TapAudioCaptureService.swift` | Coordinates Core Audio tap + AVAudioEngine mic capture |
| `CoreAudioTapManager.swift` | Creates and manages `AudioHardwareCreateProcessTap` for system audio |
| `AggregateDeviceManager.swift` | Builds tap-only aggregate devices for process exclusion |
| `AudioSynchronizer.swift` | Sample-index timeline, jitter buffering, drift tracking |
| `AudioWorker.swift` | Swift worker thread draining ring buffers to downstream consumers |
| `TapCaptureRing.swift` | Lock-free ring buffer for system audio (IOProc writes, worker reads) |
| `MicCaptureRing.swift` | Lock-free ring buffer for microphone audio |
| `AECProcessor.swift` | Echo cancellation (render-to-capture NLMS) |
| `FileOutputService.swift` | AVAssetWriter dual-file output |
| `TranscriptionService.swift` | WhisperKit integration, resampling, **loadAudioFile()** |
| `TranscriptionCoordinator.swift` | Model lifecycle, audio buffering, **reprocessTranscript()** |
| `AudioConfiguration.swift` | Centralized constants |

## Best Practices

- **System audio permission model**: Use tap-probe at session start (attempt `AudioHardwareCreateProcessTap` and observe the result) rather than calling `CGPreflightScreenCaptureAccess()` as a preflight. Cache the permission result in `UserDefaults` so subsequent launches can skip the probe.
- **RT audio callback constraints**: IOProc callbacks run on a real-time thread. No heap allocation, no Objective-C messaging, no lock acquisition. Use only lock-free ring buffers (`TapCaptureRing`, `MicCaptureRing`) to hand off samples.
- **WhisperKit sample rate**: WhisperKit requires 16 kHz mono audio. Always resample from the 48 kHz capture rate using `TranscriptionService.resampleToWhisperFormat()`.
- **Minimum macOS version**: `AudioHardwareCreateProcessTap` is available on macOS 14.2+. The app deployment target is **macOS 26.0** (`MACOSX_DEPLOYMENT_TARGET = 26.0` in `project.pbxproj`), which satisfies this requirement.

## Change History

| Date | Change | Reason |
|------|--------|--------|
| 2026-01-16 | Added reprocessing documentation | Document reprocess flow and AVAudioConverter bug fix |
| 2026-01-16 | Initial specification | Document audio pipeline architecture |
