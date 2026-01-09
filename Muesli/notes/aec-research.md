# Acoustic Echo Cancellation Research Findings

## Research Date
2025-01-XX

## Problem
When recording meetings, the microphone picks up audio from speakers, causing feedback/echo in the microphone recording. This degrades transcription quality.

## Current Architecture
- Audio arrives via `CMSampleBuffer` callbacks from ScreenCaptureKit
- System audio: 48kHz stereo Float32
- Microphone audio: 48kHz mono Float32
- Buffers processed synchronously (cannot block)
- Both streams resampled to 16kHz mono for transcription
- Audio also saved to disk (CAF files)

## Research Findings

### 1. Native macOS APIs

#### AVAudioUnitVoiceProcessingUnit
- **Status**: iOS-only API
- **Finding**: `AVAudioUnitVoiceProcessingUnit` is not available on macOS
- **Alternative**: macOS has `kAudioUnitSubType_VoiceProcessingIO` at Core Audio level
- **Challenge**: Requires AVAudioEngine architecture, but we use ScreenCaptureKit directly
- **Verdict**: Not directly applicable to our architecture

#### Core Audio VoiceProcessingIO
- **Status**: Available on macOS 10.12+
- **Finding**: Low-level Core Audio audio unit with AEC capabilities
- **Pros**: Native, optimized, well-tested
- **Cons**: Requires Core Audio integration, may not work well with ScreenCaptureKit pipeline
- **Verdict**: Possible but requires significant architecture changes

### 2. Third-Party Libraries

#### WebRTC Audio Processing
- **Status**: Available, BSD-licensed
- **Finding**: Includes `webrtc::EchoCancellation` module
- **Pros**: Battle-tested, production-ready, good performance
- **Cons**: C++ library, requires bridging to Swift, may be overkill
- **Integration**: Precompiled binaries available for macOS
- **Verdict**: Viable option, requires C++ bridging

#### SpeexDSP
- **Status**: Available, BSD-licensed
- **Finding**: Open-source library with AEC module
- **Pros**: Lightweight, well-documented, simpler than WebRTC
- **Cons**: Older codebase, may need updates
- **Verdict**: Viable option, simpler than WebRTC

#### RNNoise
- **Status**: Available, MIT-licensed
- **Finding**: Neural network-based noise suppression
- **Pros**: Modern approach, good results
- **Cons**: Not specifically designed for AEC, may not handle echo well
- **Verdict**: Less suitable for AEC specifically

### 3. Signal Processing Approaches

#### Adaptive Filtering (LMS/NLMS)
- **Concept**: Use system audio as reference signal, adaptively filter microphone signal
- **Pros**: Well-understood algorithm, can be implemented in Swift/C
- **Cons**: Requires tuning, may not handle non-linearities well
- **Implementation**: Moderate complexity
- **Verdict**: Viable for prototyping and validation

#### Spectral Subtraction
- **Concept**: Analyze frequency domain, subtract echo spectrum from microphone spectrum
- **Pros**: Can handle some non-linear distortions
- **Cons**: May introduce artifacts, computationally intensive
- **Verdict**: More complex, may have quality issues

#### Cross-Correlation & Delay Estimation
- **Concept**: Estimate delay between reference and echo, then subtract
- **Pros**: Simple concept
- **Cons**: Requires accurate delay estimation, may not handle room acoustics well
- **Verdict**: Less robust for real-world scenarios

## Recommended Approach

### Phase 1: Prototype Adaptive Filter
1. Implement simple NLMS (Normalized Least Mean Squares) adaptive filter in Swift
2. Use system audio as reference signal
3. Process microphone audio to remove echo
4. Test with sample audio to validate approach
5. Measure CPU impact

### Phase 2: Evaluate Production Solution
Based on prototype results:
- If adaptive filter works well: Optimize and use it
- If not sufficient: Integrate WebRTC or SpeexDSP library

### Integration Point
- Process microphone audio in buffer handler before:
  - Transcription (to improve transcription quality)
  - File output (to improve saved audio quality)
- Apply AEC to microphone stream only (system audio is reference)

### Timing Considerations
- System audio and microphone audio arrive separately
- Need to align reference signal (system audio) with microphone signal
- Use `CMSampleBuffer` presentation timestamps for synchronization
- May need buffering to handle timing differences

## Implementation Notes

### Adaptive Filter Requirements
- Reference signal: System audio (what's playing through speakers)
- Input signal: Microphone audio (may contain echo)
- Output: Clean microphone audio (echo removed)
- Filter length: Typically 128-512 taps
- Learning rate: Adaptive based on signal characteristics

### Performance Considerations
- Must process synchronously in callback (cannot block)
- NLMS is O(n) per sample, should be fast enough
- May need to process in chunks for efficiency
- Consider SIMD optimizations if needed

## Timing Synchronization Analysis

### Current Implementation
- System audio and microphone audio arrive separately via `CMSampleBuffer` callbacks
- Each buffer has a presentation timestamp (`CMSampleBufferGetPresentationTimeStamp`)
- `FileOutputService` uses timestamps to start AVAssetWriter sessions
- Buffers are processed synchronously (cannot block)

### Timing Considerations for AEC
1. **Delay between streams**: System audio may arrive before/after corresponding microphone audio
2. **Acoustic delay**: Physical delay between speaker output and microphone pickup (typically 10-50ms)
3. **Processing delay**: ScreenCaptureKit may introduce small delays
4. **Synchronization strategy**: 
   - Store system audio buffers with timestamps
   - When microphone audio arrives, find matching system audio by timestamp
   - Account for acoustic delay (echo arrives after reference signal)
   - Use CMTime comparison to find closest match

### Implementation Approach
- Store recent system audio buffers (last 10 buffers, ~100-200ms of audio)
- Match by timestamp with tolerance for acoustic delay
- Apply AEC at 48kHz (before resampling) for better quality
- Process microphone samples using matching system samples as reference

## Prototype Implementation

### EchoCancellationService
- **Algorithm**: NLMS (Normalized Least Mean Squares) adaptive filter
- **Filter length**: 256 taps (configurable)
- **Learning rate**: 0.3 (configurable)
- **Max delay**: 100ms (configurable)
- **Thread-safe**: Uses NSLock for synchronization

### Integration Points
1. **For Transcription**: Apply AEC before resampling to 16kHz
   - Extract samples from CMSampleBuffer
   - Apply AEC using matching system audio
   - Use processed samples for transcription
   
2. **For File Output**: (Future enhancement)
   - Option A: Apply AEC and create new CMSampleBuffer (complex)
   - Option B: Post-process audio files after recording (not real-time)
   - Option C: Apply AEC in buffer handler and create modified CMSampleBuffer

### Current Status
- ✅ Prototype EchoCancellationService implemented
- ⏳ Integration into audio pipeline (in progress)
- ⏳ Testing and validation needed

## Next Steps
1. ✅ Research AVAudioUnitVoiceProcessingUnit macOS availability
2. ✅ Evaluate WebRTC AEC integration feasibility
3. ✅ Prototype simple adaptive filter (LMS) to validate approach
4. ✅ Analyze timing synchronization between streams
5. ✅ Integrate AEC into audio pipeline
6. ⏳ Test with real audio to validate effectiveness
7. ⏳ Determine final implementation strategy (optimize or use library)

## Implementation Status

### Completed
- ✅ EchoCancellationService implemented with NLMS adaptive filter
- ✅ Integration into audio pipeline (buffer handler)
- ✅ System audio storage with timestamp synchronization
- ✅ AEC reset on recording start/stop
- ✅ User preference toggle (`isEchoCancellationEnabled`)
- ✅ Helper method to extract samples from CMSampleBuffer

### Integration Details
- AEC processes microphone audio at 48kHz (before resampling)
- System audio stored with timestamps for synchronization
- Matching performed by timestamp with tolerance for acoustic delay
- Processed samples resampled to 16kHz for transcription
- AEC can be enabled/disabled via UserDefaults preference

### Testing Needed
- Validate AEC effectiveness with real audio
- Measure CPU impact during recording
- Test with various echo scenarios (different delays, volumes)
- Verify transcription quality improvement
- Test edge cases (no system audio, delayed system audio, etc.)

### Future Enhancements
- Apply AEC to saved audio files (post-processing or real-time CMSampleBuffer modification)
- Adaptive learning rate based on signal characteristics
- Double-talk detection to prevent canceling user's voice
- Performance optimizations (SIMD, chunked processing)
