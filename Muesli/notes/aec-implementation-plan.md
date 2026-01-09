# Acoustic Echo Cancellation Implementation Plan

## Problem Statement

When recording meetings, Muesli captures both system audio (meeting participants) and microphone audio (user's voice). If the microphone picks up audio from the speakers, we get feedback/echo in the microphone recording, which degrades transcription quality.

**Goal**: Implement acoustic echo cancellation (AEC) to remove echo from microphone audio before transcription and file saving.

## Research Findings

### Native macOS APIs
- ✅ **AVAudioUnitVoiceProcessingUnit**: iOS-only, not available on macOS
- ✅ **Core Audio VoiceProcessingIO**: Available but requires AVAudioEngine architecture (we use ScreenCaptureKit)
- **Verdict**: Not directly applicable to our architecture

### Third-Party Libraries
- ✅ **WebRTC AEC**: Available (BSD-licensed), production-ready, requires C++ bridging
- ✅ **SpeexDSP**: Available (BSD-licensed), lightweight, simpler than WebRTC
- ✅ **RNNoise**: MIT-licensed, neural network-based, not specifically designed for AEC
- **Verdict**: WebRTC and SpeexDSP are viable options if prototype is insufficient

### Signal Processing Approaches
- ✅ **Adaptive Filtering (NLMS)**: Well-understood algorithm, implementable in Swift
- ✅ **Spectral Subtraction**: More complex, may introduce artifacts
- ✅ **Cross-Correlation**: Less robust for real-world scenarios
- **Verdict**: NLMS adaptive filter chosen for prototype

## Implementation Strategy

**Approach**: Implement NLMS (Normalized Least Mean Squares) adaptive filter as prototype. If effective, optimize and use; if not sufficient, integrate WebRTC or SpeexDSP library.

**Integration Point**: Process microphone audio in buffer handler before transcription and file output.

**Timing**: Use CMSampleBuffer presentation timestamps to synchronize system audio (reference) with microphone audio (input).

## File Modifications

### ✅ New Files Created

- [x] **`Muesli/Services/EchoCancellationService.swift`**
  - NLMS adaptive filter implementation
  - Filter length: 256 taps (configurable)
  - Learning rate: 0.3 (configurable)
  - Max delay: 100ms (configurable)
  - Thread-safe with NSLock
  - Timestamp-based synchronization
  - Helper method: `extractSamples(from:)` to extract Float32 samples from CMSampleBuffer

- [x] **`Muesli/notes/aec-research.md`**
  - Research findings documentation
  - Implementation notes
  - Testing recommendations
  - Future enhancements

### ✅ Files Modified

- [x] **`Muesli/ViewModels/MuesliViewModel.swift`**
  - Added `echoCancellationService` property (EchoCancellationService instance)
  - Added `isEchoCancellationEnabled` property (UserDefaults-backed toggle)
  - Modified buffer handler to:
    - Store system audio samples with timestamps when AEC enabled
    - Extract microphone samples at 48kHz
    - Apply AEC processing to microphone samples
    - Resample processed samples to 16kHz for transcription
  - Added AEC reset calls:
    - On recording start (`startRecordingAsync`)
    - On recording stop (`stopRecordingAsync`)
    - On recording discard (`discardRecordingAsync`)
    - On recording interruption (`stopRecordingAfterInterruption`)

- [x] **`Muesli/Services/TranscriptionService.swift`**
  - Added public `resampleSamples()` method
  - Wraps private `resampleWithAVAudioConverter()` for use by AEC service
  - Enables resampling of AEC-processed samples from 48kHz to 16kHz

## Implementation Details

### Echo Cancellation Service Architecture

```
System Audio (Reference Signal)
    ↓
[Store with timestamp]
    ↓
[Buffer Management]
    ↓
Microphone Audio (Input Signal)
    ↓
[Find matching system audio by timestamp]
    ↓
[NLMS Adaptive Filter]
    ↓
Clean Microphone Audio (Echo Removed)
    ↓
[Resample to 16kHz]
    ↓
Transcription Service
```

### Key Components

1. **Filter Coefficients**: 256-tap adaptive filter that learns echo characteristics
2. **Reference Buffer**: Stores recent system audio samples for echo prediction
3. **Timestamp Matching**: Finds system audio buffer closest to microphone timestamp
4. **NLMS Algorithm**: Updates filter coefficients based on error signal

### Processing Flow

1. **System Audio Arrives**:
   - Extract Float32 samples (convert stereo to mono if needed)
   - Store samples with presentation timestamp in AEC service

2. **Microphone Audio Arrives**:
   - Extract Float32 samples at 48kHz
   - Find matching system audio by timestamp
   - Apply NLMS adaptive filter to remove echo
   - Resample processed samples to 16kHz
   - Feed to transcription service

### Configuration

- **Filter Length**: 256 taps (handles ~5ms echo at 48kHz)
- **Learning Rate**: 0.3 (balances adaptation speed vs stability)
- **Max Delay**: 100ms (handles acoustic delays)
- **Sample Rate**: 48kHz (matches ScreenCaptureKit output)

## Testing Checklist

### Functional Testing
- [ ] Test with real meeting audio (speakers on)
- [ ] Verify echo reduction in microphone recording
- [ ] Test transcription quality improvement
- [ ] Test with AEC disabled (baseline comparison)
- [ ] Test with varying speaker volumes
- [ ] Test with different microphone positions

### Edge Cases
- [ ] No system audio available (should pass through unchanged)
- [ ] Delayed system audio (timestamp mismatch)
- [ ] Very loud echo (extreme case)
- [ ] User speaking while echo present (double-talk)
- [ ] Rapid volume changes

### Performance Testing
- [ ] Measure CPU usage during recording
- [ ] Verify no audio dropouts or glitches
- [ ] Test with long recordings (30+ minutes)
- [ ] Monitor memory usage (buffer management)

### Integration Testing
- [ ] Verify AEC reset on recording start/stop
- [ ] Test with microphone mute/unmute
- [ ] Test with app switching during recording
- [ ] Verify saved audio files (with/without AEC)

## User Experience

### Current Behavior
- AEC is **disabled by default**
- Can be enabled via `viewModel.isEchoCancellationEnabled = true`
- No UI toggle yet (can be added to Preferences)

### Future Enhancements
- Add UI toggle in Preferences view
- Show AEC status indicator during recording
- Adaptive learning rate based on signal characteristics
- Double-talk detection to prevent canceling user's voice
- Apply AEC to saved audio files (post-processing or real-time)

## Performance Considerations

### Current Implementation
- Processes synchronously in audio callback (cannot block)
- NLMS is O(n) per sample - should be fast enough
- Filter operations are simple multiply-add operations
- Buffer management uses NSLock for thread safety

### Optimization Opportunities
- SIMD optimizations for filter operations
- Chunked processing for better cache locality
- Pre-allocate buffers to reduce allocations
- Consider moving to background queue if CPU impact is high

## Known Limitations

1. **No Double-Talk Detection**: May cancel user's voice if speaking while echo is present
2. **Fixed Filter Length**: May not handle very long echo delays (>100ms)
3. **No Adaptive Learning Rate**: Fixed learning rate may not be optimal for all scenarios
4. **File Output Not Processed**: AEC only applied to transcription, not saved audio files
5. **Simple Timestamp Matching**: May not handle complex timing scenarios perfectly

## Future Work

### Short Term
- [ ] Add UI toggle in Preferences
- [ ] Test with real-world scenarios
- [ ] Measure and optimize performance
- [ ] Add logging/metrics for AEC effectiveness

### Medium Term
- [ ] Apply AEC to saved audio files
- [ ] Implement double-talk detection
- [ ] Adaptive learning rate
- [ ] Performance optimizations (SIMD, chunked processing)

### Long Term
- [ ] Evaluate WebRTC integration if prototype insufficient
- [ ] Machine learning-based echo cancellation
- [ ] Real-time AEC quality metrics
- [ ] User-configurable AEC parameters

## References

- Research findings: `Muesli/notes/aec-research.md`
- Implementation: `Muesli/Services/EchoCancellationService.swift`
- Integration: `Muesli/ViewModels/MuesliViewModel.swift`

## Status

✅ **Implementation Complete** - Ready for testing

All file modifications have been completed. The AEC service is integrated into the audio pipeline and ready for real-world testing. Next steps are functional testing and performance validation.
