import AVFoundation
import CoreMedia
import Foundation
import os.lock
import QuartzCore

// MARK: - Helper Extensions

extension EchoCancellationService {
    /// Extract Float32 samples from CMSampleBuffer at original sample rate
    /// - Parameter sampleBuffer: The audio sample buffer
    /// - Returns: Mono Float32 samples, or nil if extraction fails
    static func extractSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }
        
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )
        
        guard status == kCMBlockBufferNoErr, let data = dataPointer else {
            return nil
        }
        
        // Get format info to determine channel count
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        
        let channelCount = Int(asbd.pointee.mChannelsPerFrame)
        let bitsPerChannel = Int(asbd.pointee.mBitsPerChannel)
        let formatFlags = asbd.pointee.mFormatFlags
        let isFloat = (formatFlags & kAudioFormatFlagIsFloat) != 0
        let sampleRate = asbd.pointee.mSampleRate
        
        // Convert bytes to Float32 samples
        let floatCount = length / MemoryLayout<Float>.size
        let floatPointer = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: floatCount)
        
        if channelCount == 2 && isFloat && bitsPerChannel == 32 {
            // Stereo Float32: convert to mono by averaging
            let frameCount = floatCount / 2
            var monoSamples: [Float] = []
            monoSamples.reserveCapacity(frameCount)
            for i in 0..<frameCount {
                let left = floatPointer[i * 2]
                let right = floatPointer[i * 2 + 1]
                monoSamples.append((left + right) / 2.0)
            }
            return monoSamples
        } else if channelCount == 1 && isFloat && bitsPerChannel == 32 {
            // Mono Float32: return as-is
            let samples = Array(UnsafeBufferPointer(start: floatPointer, count: floatCount))
            return samples
        } else {
            // Unsupported format
            return nil
        }
    }
    
    /// Create CMSampleBuffer from Float32 samples
    /// Converts from mono Float32 to stereo Float32 (optional resample) for file output
    /// - Parameters:
    ///   - samples: Float32 mono samples at source sample rate
    ///   - timestamp: Presentation timestamp for the buffer
    ///   - sourceSampleRate: Source sample rate (default: 48000)
    ///   - targetSampleRate: Target sample rate (default: 48000)
    /// - Returns: CMSampleBuffer in Float32 stereo format, or nil if conversion fails
    static func createSampleBuffer(
        from samples: [Float],
        timestamp: CMTime,
        sourceSampleRate: Int = 48000,
        targetSampleRate: Int = 48000
    ) -> CMSampleBuffer? {
        guard !samples.isEmpty else { return nil }
        
        // 1. Resample from sourceSampleRate to targetSampleRate (if needed)
        let resampled = resampleFloat32(
            samples: samples,
            sourceSampleRate: sourceSampleRate,
            targetSampleRate: targetSampleRate
        )
        
        guard !resampled.isEmpty else { return nil }
        
        // 2. Convert mono Float32 to stereo Float32 (duplicate channel)
        let stereoFloat32: [Float] = resampled.flatMap { sample in
            [sample, sample]
        }
        
        // 3. Create AudioStreamBasicDescription for Float32 stereo
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(targetSampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,  // 4 bytes per sample * 2 channels
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        
        // 4. Create format description
        var formatDesc: CMFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: nil,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        
        guard status == noErr, let format = formatDesc else {
            return nil
        }
        
        // 5. Create block buffer with the stereo Float32 data
        let dataSize = stereoFloat32.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        
        guard status == noErr, let blockBuf = blockBuffer else {
            return nil
        }
        
        // 6. Copy stereo Float32 data to block buffer
        status = stereoFloat32.withUnsafeBufferPointer { bufferPtr in
            CMBlockBufferReplaceDataBytes(
                with: bufferPtr.baseAddress!,
                blockBuffer: blockBuf,
                offsetIntoDestination: 0,
                dataLength: dataSize
            )
        }
        
        guard status == noErr else {
            return nil
        }
        
        // 7. Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        let sampleCount = resampled.count
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(targetSampleRate)),
            presentationTimeStamp: timestamp,
            decodeTimeStamp: CMTime.invalid
        )
        
        status = CMSampleBufferCreate(
            allocator: nil,
            dataBuffer: blockBuf,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: sampleCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        
        return (status == noErr) ? sampleBuffer : nil
    }
    
    /// Simple resampling using linear interpolation (public version)
    /// - Parameters:
    ///   - samples: Input samples
    ///   - sourceSampleRate: Source sample rate
    ///   - targetSampleRate: Target sample rate
    /// - Returns: Resampled samples
    static func resampleFloat32Public(
        samples: [Float],
        sourceSampleRate: Int,
        targetSampleRate: Int
    ) -> [Float] {
        resampleFloat32(samples: samples, sourceSampleRate: sourceSampleRate, targetSampleRate: targetSampleRate)
    }
    
    /// Simple resampling using linear interpolation
    /// - Parameters:
    ///   - samples: Input samples
    ///   - sourceSampleRate: Source sample rate
    ///   - targetSampleRate: Target sample rate
    /// - Returns: Resampled samples
    private static func resampleFloat32(
        samples: [Float],
        sourceSampleRate: Int,
        targetSampleRate: Int
    ) -> [Float] {
        guard sourceSampleRate != targetSampleRate else { return samples }
        guard !samples.isEmpty else { return [] }
        
        let ratio = Double(sourceSampleRate) / Double(targetSampleRate)
        let outputCount = Int(Double(samples.count) / ratio)
        
        guard outputCount > 0 else { return [] }
        
        var output = [Float](repeating: 0, count: outputCount)
        
        for i in 0..<outputCount {
            let sourceIndex = Double(i) * ratio
            let lowerIndex = Int(sourceIndex)
            let upperIndex = min(lowerIndex + 1, samples.count - 1)
            let fraction = Float(sourceIndex - Double(lowerIndex))
            
            // Linear interpolation
            output[i] = samples[lowerIndex] * (1.0 - fraction) + samples[upperIndex] * fraction
        }
        
        return output
    }
}

/// Statistics for gap tracking, used for recording-end logging
struct GapStatistics {
    let gapCount: Int
    let totalGapSamples: Int64
    let maxGapSamples: Int64
    
    var avgGapMs: Double {
        guard gapCount > 0 else { return 0 }
        return Double(totalGapSamples) / Double(gapCount) / 48.0
    }
    
    var totalGapMs: Double {
        Double(totalGapSamples) / 48.0
    }
    
    var maxGapMs: Double {
        Double(maxGapSamples) / 48.0
    }
}

/// Service for acoustic echo cancellation using adaptive filtering
/// Uses NLMS (Normalized Least Mean Squares) algorithm to remove echo from microphone audio
/// Reference signal: System audio (what's playing through speakers)
/// Input signal: Microphone audio (may contain echo)
/// Output: Clean microphone audio (echo removed)
///
/// Known limitations:
/// - No Double-Talk Detection (DTD): Algorithm assumes speaker and listener don't talk simultaneously
/// - No NLP (Non-Linear Processing): Uses linear NLMS only, no residual echo suppression
/// - Filter length constraint: Echo path must be shorter than filterLength * samplePeriod
final class EchoCancellationService: @unchecked Sendable, EchoCancellationServiceProtocol {
    // MARK: - AEC Diagnostic Counters
    
    /// Thread-safe counter for match rate tracking
    /// Uses OSAllocatedUnfairLock per AGENTS.md for audio callback safety
    private static let matchCounterLock = OSAllocatedUnfairLock(initialState: (hits: 0, misses: 0))
    
    // MARK: - Gap Detection
    
    /// Injectable time provider for testability (default: SystemTimeProvider using CACurrentMediaTime)
    private let timeProvider: TimeProvider
    
    /// Pre-allocated silence buffer to avoid allocation inside lock (500ms max at 48kHz = 24000 samples)
    private let preallocatedSilence: [Float]
    
    /// Drift monitoring task - created when recording starts, cancelled when recording stops
    private var driftMonitoringTask: Task<Void, Never>?
    
    // MARK: - Configuration
    
    /// Filter length (number of taps)
    /// Typical values: 128-512 taps
    /// Longer filters handle longer echo delays but require more computation
    private let filterLength: Int
    
    /// Learning rate (step size) for adaptive filter
    /// Typical values: 0.1-0.5
    /// Higher values adapt faster but may be less stable
    private let learningRate: Float
    
    /// Regularization constant to prevent division by zero
    private let epsilon: Float = 1e-6
    
    /// Sample rate (must match input audio)
    private let sampleRate: Int
    
    /// Maximum delay to handle (in samples)
    /// This determines how much history we keep
    private let maxDelaySamples: Int
    
    /// Maximum number of buffers to keep for synchronization
    /// Uses AudioConfiguration.maxSystemAudioBuffers to handle ~3 seconds of audio
    /// and accommodate clock drift between mic and system audio streams (~1-2% drift is common)
    private let maxBuffers: Int
    
    /// Acoustic delay in samples (DAC + propagation + ADC latency)
    private let acousticDelaySamples: Int
    
    /// Synchronization timeout: 5 seconds covers worst-case SCK startup delay
    /// while preventing indefinite blocking if one stream fails
    private let syncTimeoutSeconds: TimeInterval = 5.0
    
    // MARK: - Diagnostic Counters (for debugging AEC sync issues)
    
    /// Counter for INDEX diagnostic logging (every Nth synced buffer)
    private nonisolated(unsafe) static var indexDiagCount = 0
    
    /// Counter for LOOKUP diagnostic logging (every Nth lookup)
    private nonisolated(unsafe) static var lookupDiagCount = 0
    
    // MARK: - State (Thread-Safe via OSAllocatedUnfairLock)
    
    /// Sample-count-based buffer for stream synchronization
    /// Uses sample indices instead of timestamps to avoid clock domain mismatch
    private struct IndexedBuffer {
        let samples: [Float]
        let startSampleIndex: Int64  // Sample index from recording start
    }
    
    /// Circular buffer for O(1) append/access operations on reference signal
    private struct CircularBuffer {
        var samples: [Float]
        var writeIndex: Int = 0
        let capacity: Int
        
        init(capacity: Int) {
            self.capacity = capacity
            self.samples = Array(repeating: 0.0, count: capacity)
        }
        
        mutating func append(_ sample: Float) {
            samples[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
        }
        
        /// Get sample at offset from the most recent write position
        /// offsetFromEnd = 0 returns the most recently written sample
        func sample(at offsetFromEnd: Int) -> Float {
            guard offsetFromEnd >= 0 && offsetFromEnd < capacity else { return 0.0 }
            let idx = (writeIndex - offsetFromEnd - 1 + capacity) % capacity
            return samples[idx]
        }
        
        mutating func reset() {
            samples = Array(repeating: 0.0, count: capacity)
            writeIndex = 0
        }
    }
    
    /// All mutable state wrapped for thread-safe access
    /// IMPORTANT: Sample counting assumes both streams are 48kHz.
    /// RecordingController ensures this via resampling before AEC.
    /// If sample rates diverge, counts will misalign catastrophically.
    private struct AECState {
        // Number of buffers to average for offset calculation (~1 second of data)
        // At 4096 samples/buffer @ 48kHz = ~85ms/buffer, so 12 buffers ≈ 1 second
        static let kBuffersToAverage = 12
        
        var filterCoefficients: [Float]
        var referenceBuffer: CircularBuffer
        var systemAudioBuffers: [IndexedBuffer]  // Changed from TimestampedBuffer
        var totalSystemSamples: Int64 = 0        // Running count of system samples
        var totalMicSamples: Int64 = 0           // Running count of mic samples
        // Stream synchronization
        var systemAudioStarted: Bool = false
        var microphoneStarted: Bool = false
        var streamsSynchronized: Bool = false
        var streamSyncStartTime: Date?           // For timeout detection
        // Delivery offset tracking (for stream synchronization)
        var systemAudioBufferTimes: [Double] = []   // CACurrentMediaTime() for first N buffers
        var microphoneBufferTimes: [Double] = []    // CACurrentMediaTime() for first N buffers
        var deliveryOffsetSamples: Int64 = 0        // Positive = mic ahead, negative = system ahead
        var offsetCalculated: Bool = false          // True once we have enough samples to calculate
        
        // MARK: - Gap Detection State (per plan: AEC clock drift fix)
        
        /// Last wall-clock time when system audio buffer was received
        var lastSystemBufferTime: Double = 0
        /// Last wall-clock time when microphone buffer was received
        var lastMicBufferTime: Double = 0
        /// Count of system audio buffers received (for first-buffer detection)
        var systemBufferCount: Int = 0
        /// Count of microphone buffers received (for first-buffer detection)
        var micBufferCount: Int = 0
        /// Number of positive gap events logged (for rate limiting)
        var gapLogCount: Int = 0
        /// Number of negative gap (early arrival) events logged (for rate limiting)
        var negativeGapLogCount: Int = 0
        /// Total samples added as silence to fill gaps
        var totalGapSamples: Int64 = 0
        /// Maximum gap size in samples (for end-of-recording stats)
        var maxGapSamples: Int64 = 0
        
        // MARK: - Offset Validation State (per AEC offset validation fix plan)
        
        /// Number of times bounds check fallback was triggered (target > totalSystemSamples)
        var boundsCheckFallbackCount: Int = 0
        /// Counter for periodic OFFSET_CHECK logging (every 2880 buffers = 60 seconds)
        var offsetCheckCounter: Int = 0
        
        // MARK: - Drift Monitoring State
        
        /// Recording start time for drift monitoring (wall-clock)
        var recordingStartTime: Double = 0
    }
    
    /// Thread-safe state using OSAllocatedUnfairLock (AGENTS.md requirement)
    private let state: OSAllocatedUnfairLock<AECState>
    
    // MARK: - Initialization
    
    /// Initialize echo cancellation service
    /// - Parameters:
    ///   - filterLength: Number of filter taps (default: AudioConfiguration.aecFilterLength)
    ///   - learningRate: Learning rate for adaptation (default: AudioConfiguration.aecLearningRate)
    ///   - sampleRate: Audio sample rate (default: AudioConfiguration.captureSampleRate)
    ///   - maxDelayMs: Maximum echo delay to handle in milliseconds (default: 100ms)
    ///   - acousticDelayMs: Acoustic delay (DAC + propagation + ADC) in milliseconds (default: AudioConfiguration.aecAcousticDelayMs)
    ///   - timeProvider: Injectable time source for testing (default: SystemTimeProvider)
    ///   - maxBuffers: Maximum system audio buffers to retain (default: AudioConfiguration.maxSystemAudioBuffers)
    init(
        filterLength: Int = AudioConfiguration.aecFilterLength,
        learningRate: Float = AudioConfiguration.aecLearningRate,
        sampleRate: Int = AudioConfiguration.captureSampleRate,
        maxDelayMs: Int = 100,
        acousticDelayMs: Int = AudioConfiguration.aecAcousticDelayMs,
        timeProvider: TimeProvider = SystemTimeProvider(),
        maxBuffers: Int = AudioConfiguration.maxSystemAudioBuffers
    ) {
        self.filterLength = filterLength
        self.learningRate = learningRate
        self.sampleRate = sampleRate
        self.maxDelaySamples = (sampleRate * maxDelayMs) / 1000
        self.acousticDelaySamples = (sampleRate * acousticDelayMs) / 1000
        self.timeProvider = timeProvider
        self.maxBuffers = maxBuffers
        
        // Pre-allocate silence buffer for gap filling (avoid allocation inside lock)
        // Size: 500ms max at 48kHz = 24000 samples
        let maxGapSamples = AudioConfiguration.aecMaxGapMs * AudioConfiguration.captureSampleRate / 1000
        self.preallocatedSilence = Array(repeating: Float(0.0), count: maxGapSamples)
        
        // Calculate circular buffer capacity dynamically based on maxDelaySamples:
        // Need: maxDelaySamples + filterLength + maxMicFrameSize (4096) + margin
        // With maxDelayMs=3000: 144000 + 1024 + 4096 + margin ≈ 160,000 samples
        let bufferCapacity = maxDelaySamples + filterLength + 8192  // 8192 = frame size + margin
        
        self.state = OSAllocatedUnfairLock(initialState: AECState(
            filterCoefficients: Array(repeating: 0.0, count: filterLength),
            referenceBuffer: CircularBuffer(capacity: bufferCapacity),
            systemAudioBuffers: []
        ))
    }
    
    // MARK: - Public API
    
    /// Struct to hold gap detection log info returned from lock
    private struct GapLogInfo: Sendable {
        var largeGapWarning: Int64? = nil
        var gapSamples: Int64? = nil
        var gapMs: Double? = nil
        var isNegative: Bool = false
    }
    
    /// Store system audio as reference signal for echo cancellation
    /// - Parameter samples: System audio samples (reference signal - what's playing through speakers)
    func storeSystemAudio(samples: [Float]) {
        // Empty input guard - avoid unnecessary lock acquisition
        guard !samples.isEmpty else { return }
        
        // Get logging info from lock (values returned, not mutated captures)
        let logInfo: GapLogInfo = state.withLock { state in
            let now = timeProvider.currentTime()
            var info = GapLogInfo()
            
            // Record arrival times for first N buffers (for offset averaging)
            if state.systemAudioBufferTimes.count < AECState.kBuffersToAverage {
                state.systemAudioBufferTimes.append(now)
            }
            
            if !state.systemAudioStarted {
                state.systemAudioStarted = true
                checkAndSynchronizeStreams(&state)
            } else if !state.offsetCalculated {
                // Keep trying to calculate offset until we have enough samples
                checkAndSynchronizeStreams(&state)
            }
            
            // MARK: - Gap Detection (per plan: AEC clock drift fix)
            // Reference: https://nonstrict.eu/blog/2024/handling-audio-capture-gaps-on-macos
            
            var gapSamples: Int64 = 0
            
            // First buffer: initialize timing (NO EARLY RETURN - still store buffer below)
            if state.systemBufferCount == 0 {
                state.lastSystemBufferTime = now
            } else {
                // Subsequent buffers: check for gap
                let elapsed = now - state.lastSystemBufferTime
                let expectedSamples = Int64(elapsed * Double(AudioConfiguration.captureSampleRate))
                let actualSamples = Int64(samples.count)
                gapSamples = expectedSamples - actualSamples
                
                let gapThreshold = Int64(AudioConfiguration.aecGapThresholdMs) *
                                  Int64(AudioConfiguration.captureSampleRate) / 1000
                let maxGapFill = Int64(AudioConfiguration.aecMaxGapMs) *
                                Int64(AudioConfiguration.captureSampleRate) / 1000
                
                if gapSamples > gapThreshold {
                    // Check for large gap BEFORE clamping (separate variable per v4)
                    if gapSamples > maxGapFill {
                        info.largeGapWarning = gapSamples  // Original size for warning
                        gapSamples = maxGapFill       // Clamp for actual fill
                    }
                    
                    // Use pre-allocated silence (slice, no allocation)
                    let silenceSamples = Array(preallocatedSilence.prefix(Int(gapSamples)))
                    
                    // BUFFER INDEX CONTINUITY: silence starts at current counter
                    let silenceBuffer = IndexedBuffer(
                        samples: silenceSamples,
                        startSampleIndex: state.totalSystemSamples
                    )
                    state.systemAudioBuffers.append(silenceBuffer)
                    state.totalSystemSamples += gapSamples
                    
                    // Track statistics
                    state.gapLogCount += 1
                    state.totalGapSamples += gapSamples
                    state.maxGapSamples = max(state.maxGapSamples, gapSamples)
                    
                    // Rate-limited logging (separate from large gap warning)
                    if state.gapLogCount <= 10 || state.gapLogCount % 100 == 0 {
                        info.gapSamples = gapSamples
                        info.gapMs = Double(gapSamples) / 48.0
                    }
                } else if gapSamples < -gapThreshold {
                    // Negative gap (early arrival): log but don't adjust
                    // Use separate counter to avoid log flooding from repeated early arrivals
                    state.negativeGapLogCount += 1
                    if state.negativeGapLogCount <= 10 {
                        info.gapSamples = -gapSamples
                        info.gapMs = Double(-gapSamples) / 48.0
                        info.isNegative = true
                    }
                }
                
                state.lastSystemBufferTime = now
            }
            
            state.systemBufferCount += 1
            
            // CRITICAL FIX: Always buffer system audio, even during warmup
            // Previously we discarded pre-sync samples, but with deferred sync
            // this caused 0% match rate since there was no reference audio
            // at index 0 when sync finally happened
            // Per v4: ALWAYS store actual buffer (no early return for first buffer)
            let startIndex = state.totalSystemSamples
            state.systemAudioBuffers.append(IndexedBuffer(
                samples: samples,
                startSampleIndex: startIndex
            ))
            state.totalSystemSamples += Int64(samples.count)
            
            // Buffer pruning - prevent memory growth during long recordings
            if state.systemAudioBuffers.count > maxBuffers {
                state.systemAudioBuffers.removeFirst()
            }
            
            return info
        }
        
        // Log OUTSIDE lock (separate paths per v4)
        if let originalSize = logInfo.largeGapWarning {
            Task { await DiagnosticLogger.shared.log(.aec,
                "SYS_GAP_LARGE: \(originalSize) samples clamped to \(AudioConfiguration.aecMaxGapMs)ms - possible stream restart") }
        }
        if let samples = logInfo.gapSamples, let ms = logInfo.gapMs {
            if !logInfo.isNegative {
                Task { await DiagnosticLogger.shared.log(.aec,
                    "SYS_GAP: \(samples) samples (\(String(format: "%.1f", ms))ms)") }
            } else {
                Task { await DiagnosticLogger.shared.log(.aec,
                    "SYS_EARLY: buffer \(samples) samples early") }
            }
        }
    }
    
    /// Process microphone audio to remove echo
    /// - Parameter microphoneSamples: Microphone audio samples (may contain echo)
    /// - Returns: Clean microphone audio with echo removed
    func processMicrophoneAudio(microphoneSamples: [Float]) -> [Float] {
        // Empty input guard - avoid unnecessary lock acquisition
        guard !microphoneSamples.isEmpty else { return microphoneSamples }
        
        // Result tuple: (processed audio, optional mic gap for logging)
        let (result, micGapInfo): ([Float], Int64?) = state.withLock { state in
            let now = timeProvider.currentTime()
            var gapToLog: Int64? = nil
            
            // Record arrival times for first N buffers (for offset averaging)
            if state.microphoneBufferTimes.count < AECState.kBuffersToAverage {
                state.microphoneBufferTimes.append(now)
            }
            
            if !state.microphoneStarted {
                state.microphoneStarted = true
                checkAndSynchronizeStreams(&state)
            } else if !state.offsetCalculated {
                // Keep trying to calculate offset until we have enough samples
                checkAndSynchronizeStreams(&state)
            }
            
            // MARK: - Read-Only Mic Gap Detection (Phase 2 data collection)
            // Per plan: Log only, no gap fill - collect data to decide if mic needs gap handling
            if state.micBufferCount > 0 {
                let elapsed = now - state.lastMicBufferTime
                let expectedSamples = Int64(elapsed * Double(AudioConfiguration.captureSampleRate))
                let gap = expectedSamples - Int64(microphoneSamples.count)
                let threshold = Int64(AudioConfiguration.aecGapThresholdMs) * 48
                
                if abs(gap) > threshold {
                    // Log only - no gap fill (Phase 2 decision data)
                    gapToLog = gap
                }
            }
            state.lastMicBufferTime = now
            state.micBufferCount += 1
            
            // CRITICAL: Count mic samples BEFORE sync guard (matching storeSystemAudio behavior)
            // Both streams must count samples during warmup for correct alignment after sync
            let micStartIndex = state.totalMicSamples
            state.totalMicSamples += Int64(microphoneSamples.count)
            
            guard state.streamsSynchronized else {
                return (microphoneSamples, gapToLog)  // Pass through during warmup
            }
            
            // MARK: - Periodic Offset Check (per AEC offset validation fix plan)
            // Log offset stability every 60 seconds (2880 buffers at ~20ms/buffer)
            state.offsetCheckCounter += 1
            if state.offsetCheckCounter % 2880 == 0 {
                let actualDelta = state.totalSystemSamples - state.totalMicSamples
                let offsetError = actualDelta - state.deliveryOffsetSamples
                let checkMsg = "OFFSET_CHECK: claimed=\(state.deliveryOffsetSamples), " +
                    "actual=\(actualDelta), mismatch=\(offsetError) samples"
                Task { await DiagnosticLogger.shared.log(.aec, checkMsg) }
            }
            
            // Diagnostic: Log index calculation (every 500th synced buffer)
            Self.indexDiagCount += 1
            if Self.indexDiagCount % 500 == 1 {
                let targetSysIdx = micStartIndex - Int64(acousticDelaySamples) - state.deliveryOffsetSamples
                let indexMsg = "INDEX: micStart=\(micStartIndex), acoustic=\(acousticDelaySamples), " +
                    "offset=\(state.deliveryOffsetSamples), target=\(targetSysIdx), sysSamples=\(state.totalSystemSamples)"
                Task { await DiagnosticLogger.shared.log(.aec, indexMsg) }
            }
            
            // Account for:
            // 1. Acoustic delay (DAC + propagation + ADC): subtract to look backward
            // 2. Delivery offset: SUBTRACT the offset to align sample indices
            //    - Positive offset (mic ahead): mic index > system index for same moment → subtract to get lower system index
            //    - Negative offset (system ahead): mic index < system index for same moment → subtract negative = add
            let targetSysIndex = micStartIndex - Int64(acousticDelaySamples) - state.deliveryOffsetSamples
            
            // Handle negative index during initial acoustic delay window
            // This is normal for the first ~50ms of recording
            if targetSysIndex < 0 {
                return (microphoneSamples, gapToLog)
            }
            
            // MARK: - Bounds Check Fallback (per AEC offset validation fix plan)
            // If target exceeds available samples, fall back to pass-through
            // This preserves user's voice even if echo is present
            if targetSysIndex > state.totalSystemSamples {
                state.boundsCheckFallbackCount += 1
                
                // Log first occurrence and every 100th thereafter
                if state.boundsCheckFallbackCount == 1 || state.boundsCheckFallbackCount % 100 == 0 {
                    let errorMsg = "BOUNDS_FALLBACK: target=\(targetSysIndex) > totalSys=\(state.totalSystemSamples), " +
                        "occurred \(state.boundsCheckFallbackCount) times, using pass-through"
                    Task { await DiagnosticLogger.shared.log(.aec, errorMsg) }
                }
                
                return (microphoneSamples, gapToLog)  // Pass-through preserves user's voice
            }
            
            // Find aligned reference samples with cross-buffer support
            guard let referenceSamples = findMatchingSystemAudio(
                forSampleIndex: targetSysIndex,
                sampleCount: microphoneSamples.count,
                in: state.systemAudioBuffers
            ) else {
                return (microphoneSamples, gapToLog)
            }
            
            // Process samples using NLMS adaptive filter
            var outputSamples: [Float] = []
            outputSamples.reserveCapacity(microphoneSamples.count)
            
            for i in 0..<microphoneSamples.count {
                // Update reference buffer with O(1) circular append
                if referenceSamples.count > i {
                    state.referenceBuffer.append(referenceSamples[i])
                }
                
                // Compute predicted echo using current filter coefficients
                var predictedEcho: Float = 0.0
                for j in 0..<filterLength {
                    let sample = state.referenceBuffer.sample(at: filterLength - 1 - j)
                    predictedEcho += state.filterCoefficients[j] * sample
                }
                
                // Compute error (microphone signal - predicted echo)
                let error = microphoneSamples[i] - predictedEcho
                
                // Update filter coefficients using NLMS algorithm
                // Compute power of reference signal
                var referencePower: Float = epsilon
                for j in 0..<filterLength {
                    let sample = state.referenceBuffer.sample(at: filterLength - 1 - j)
                    referencePower += sample * sample
                }
                
                // Update coefficients: w(n+1) = w(n) + μ * error * x(n) / (||x(n)||² + ε)
                let stepSize = learningRate / referencePower
                for j in 0..<filterLength {
                    let sample = state.referenceBuffer.sample(at: filterLength - 1 - j)
                    state.filterCoefficients[j] += stepSize * error * sample
                }
                
                // Output is the error signal (microphone with echo removed)
                outputSamples.append(error)
            }
            
            return (outputSamples, gapToLog)
        }
        
        // Log mic gap OUTSIDE lock (Phase 2 data collection, no processing impact)
        if let gap = micGapInfo {
            Task { await DiagnosticLogger.shared.log(.aec,
                "MIC_GAP_DETECTED: \(gap) samples - Phase 2 data") }
        }
        
        return result
    }
    
    /// Reset filter state (call when starting new recording)
    func reset() {
        // Called when recording starts, BEFORE first audio buffers arrive
        
        // Log recording-end statistics BEFORE clearing state
        let stats: GapStatistics? = state.withLock { state in
            guard state.gapLogCount > 0 else { return nil }
            return GapStatistics(
                gapCount: state.gapLogCount,
                totalGapSamples: state.totalGapSamples,
                maxGapSamples: state.maxGapSamples
            )
        }
        
        if let stats = stats {
            Task { await DiagnosticLogger.shared.log(.aec,
                "AEC_RECORDING_END: gaps=\(stats.gapCount), total=\(stats.totalGapSamples) (\(String(format: "%.2f", stats.totalGapMs))ms), max=\(stats.maxGapSamples) (\(String(format: "%.1f", stats.maxGapMs))ms), avg=\(String(format: "%.1f", stats.avgGapMs))ms") }
        }
        
        // Stop drift monitoring
        stopDriftMonitoring()
        
        state.withLock { state in
            state.filterCoefficients = Array(repeating: 0.0, count: filterLength)
            state.referenceBuffer.reset()
            state.systemAudioBuffers.removeAll()
            state.totalSystemSamples = 0
            state.totalMicSamples = 0
            state.systemAudioStarted = false
            state.microphoneStarted = false
            state.streamsSynchronized = false
            state.streamSyncStartTime = nil  // Clear timeout tracking
            
            // Clear delivery offset tracking
            state.systemAudioBufferTimes.removeAll()
            state.microphoneBufferTimes.removeAll()
            state.deliveryOffsetSamples = 0
            state.offsetCalculated = false
            
            // Clear gap detection state
            state.lastSystemBufferTime = 0
            state.lastMicBufferTime = 0
            state.systemBufferCount = 0
            state.micBufferCount = 0
            state.gapLogCount = 0
            state.negativeGapLogCount = 0
            state.totalGapSamples = 0
            state.maxGapSamples = 0
            
            // Clear offset validation state
            state.boundsCheckFallbackCount = 0
            state.offsetCheckCounter = 0
            
            // Clear drift monitoring state
            state.recordingStartTime = 0
        }
    }
    
    /// Start drift monitoring when recording begins
    /// Call this after reset() when starting a new recording
    func startDriftMonitoring() {
        state.withLock { state in
            state.recordingStartTime = timeProvider.currentTime()
        }
        
        driftMonitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                // Wait 60 seconds
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled, let self = self else { break }
                
                await self.checkDrift()
            }
        }
    }
    
    /// Stop drift monitoring when recording ends (called by reset())
    func stopDriftMonitoring() {
        driftMonitoringTask?.cancel()
        driftMonitoringTask = nil
    }
    
    /// Check cumulative drift (called every 60 seconds by drift monitoring task)
    private func checkDrift() async {
        let (expected, actual, duration) = state.withLock { state in
            let duration = timeProvider.currentTime() - state.recordingStartTime
            let expected = Int64(duration * Double(AudioConfiguration.captureSampleRate))
            return (expected, state.totalSystemSamples, duration)
        }
        
        guard expected > 0 else { return }
        let driftPercent = abs(Double(actual - expected)) / Double(expected) * 100
        
        if driftPercent > 1.0 {
            await DiagnosticLogger.shared.log(.aec,
                "DRIFT_WARNING: \(String(format: "%.2f", driftPercent))% drift after \(String(format: "%.0f", duration))s")
        }
    }
    
    // MARK: - Private Helpers
    
    /// Synchronize streams when both have started, with timeout handling
    private func checkAndSynchronizeStreams(_ state: inout AECState) {
        let now = Date()
        
        // Calculate offset once we have enough buffer timestamps from both streams
        let kBuffersToAverage = AECState.kBuffersToAverage
        if !state.offsetCalculated &&
           state.systemAudioBufferTimes.count >= kBuffersToAverage &&
           state.microphoneBufferTimes.count >= kBuffersToAverage {
            
            // Average the timestamps to reduce jitter (especially after sleep/wake)
            let avgSysTime = state.systemAudioBufferTimes.reduce(0, +) / Double(kBuffersToAverage)
            let avgMicTime = state.microphoneBufferTimes.reduce(0, +) / Double(kBuffersToAverage)
            
            // Calculate offset: sysTime - micTime
            // Positive result = mic arrived first (mic is ahead)
            // Negative result = system arrived first (system is ahead)
            let offsetSeconds = avgSysTime - avgMicTime
            
            // Convert to samples (48kHz)
            var offsetSamples = Int64(offsetSeconds * Double(sampleRate))
            
            // Sanity check: clamp to reasonable range (±500ms = ±24000 samples)
            let maxReasonableOffset: Int64 = 24000
            if abs(offsetSamples) > maxReasonableOffset {
                // Pre-build log message to avoid Sendable issues
                let warningMsg = "SYNC_WARNING: offset \(offsetSamples) samples " +
                    "(\(String(format: "%.1f", offsetSeconds * 1000))ms) exceeds ±500ms, clamping"
                Task { await DiagnosticLogger.shared.log(.aec, warningMsg) }
                offsetSamples = max(-maxReasonableOffset, min(maxReasonableOffset, offsetSamples))
            }
            
            state.deliveryOffsetSamples = offsetSamples
            state.offsetCalculated = true
            
            // MARK: - Post-Warmup Offset Validation (per AEC offset validation fix plan)
            // Validate that calculated offset matches actual sample count difference
            // Threshold: 50ms (2400 samples) = 2x typical steady-state jitter
            let actualDelta = state.totalSystemSamples - state.totalMicSamples
            let mismatch = abs(actualDelta - state.deliveryOffsetSamples)
            let mismatchThreshold: Int64 = 2400  // 50ms at 48kHz
            
            if mismatch > mismatchThreshold {
                // Offset doesn't match reality - use actual sample difference
                var correctedOffset = actualDelta
                
                // Apply same sanity clamp as initial offset (±500ms)
                correctedOffset = max(-maxReasonableOffset, min(maxReasonableOffset, correctedOffset))
                
                let warnMsg = "OFFSET_VALIDATION: mismatch=\(mismatch) samples " +
                    "(\(String(format: "%.1f", Double(mismatch) / 48.0))ms), " +
                    "correcting offset from \(state.deliveryOffsetSamples) to \(correctedOffset)"
                Task { await DiagnosticLogger.shared.log(.aec, warnMsg) }
                
                state.deliveryOffsetSamples = correctedOffset
            }
            
            // CHANGED (per plan): Sync streams AFTER offset is calculated and validated
            // This fixes the sync window gap where AEC operated with deliveryOffsetSamples = 0
            state.streamsSynchronized = true
            // NOTE: Don't reset sample counts - buffers are already indexed with current counts
            // Resetting would cause index mismatch between buffer indices and expected lookups
            
            // Log with correct status for all cases (positive/negative/zero)
            let offsetStatus = offsetSamples > 0 ? "ahead" : (offsetSamples < 0 ? "behind" : "synced")
            let syncDuration = now.timeIntervalSince(state.streamSyncStartTime ?? now)
            let offsetMsg = "SYNC_OFFSET: delivery_offset=\(offsetSamples) samples " +
                "(\(String(format: "%.1f", offsetSeconds * 1000))ms), mic_\(offsetStatus), " +
                "sync_after=\(String(format: "%.3f", syncDuration))s"
            Task { await DiagnosticLogger.shared.log(.aec, offsetMsg) }
            
            // DIAGNOSTIC: Log full state at sync completion for debugging
            let bufferRange: String
            let avgSysBufferSize: Int
            if state.systemAudioBuffers.isEmpty {
                bufferRange = "empty"
                avgSysBufferSize = 0
            } else {
                let minIdx = state.systemAudioBuffers.first?.startSampleIndex ?? 0
                let maxIdx = (state.systemAudioBuffers.last?.startSampleIndex ?? 0) +
                    Int64(state.systemAudioBuffers.last?.samples.count ?? 0)
                bufferRange = "\(minIdx)-\(maxIdx)"
                let totalSamples = state.systemAudioBuffers.reduce(0) { $0 + $1.samples.count }
                avgSysBufferSize = totalSamples / max(1, state.systemAudioBuffers.count)
            }
            let stateMsg = "SYNC_STATE: totalSys=\(state.totalSystemSamples), " +
                "totalMic=\(state.totalMicSamples), " +
                "offset=\(state.deliveryOffsetSamples), " +
                "bufferCount=\(state.systemAudioBuffers.count), " +
                "bufferRange=\(bufferRange), " +
                "avgSysBufSize=\(avgSysBufferSize)"
            Task { await DiagnosticLogger.shared.log(.aec, stateMsg) }
            
            // Log drift rate diagnostic
            let expectedSamples = Int64(syncDuration * Double(sampleRate))
            let sysDrift = state.totalSystemSamples - expectedSamples
            let micDrift = state.totalMicSamples - expectedSamples
            let driftMsg = "SYNC_DRIFT: expected=\(expectedSamples) (for \(String(format: "%.3f", syncDuration))s), " +
                "sysDrift=\(sysDrift) (\(String(format: "%.1f", Double(sysDrift)/Double(expectedSamples)*100))%), " +
                "micDrift=\(micDrift) (\(String(format: "%.1f", Double(micDrift)/Double(expectedSamples)*100))%)"
            Task { await DiagnosticLogger.shared.log(.aec, driftMsg) }
        }
        
        // Track when first stream started (for timeout detection)
        if state.streamSyncStartTime == nil && (state.systemAudioStarted || state.microphoneStarted) {
            state.streamSyncStartTime = now
        }
        
        // Timeout after 5 seconds - fallback to pass-through mode (UNCHANGED per plan)
        // This ensures we never block indefinitely if offset calculation fails
        if let startTime = state.streamSyncStartTime,
           now.timeIntervalSince(startTime) > syncTimeoutSeconds,
           !state.streamsSynchronized {
            // NOTE: Don't reset sample counts - buffers are already indexed with current counts
            state.streamsSynchronized = true  // Proceed anyway to avoid indefinite blocking
            let timeoutMsg = "SYNC_TIMEOUT: streams not synchronized after \(syncTimeoutSeconds)s, using pass-through mode"
            Task { await DiagnosticLogger.shared.log(.aec, timeoutMsg) }
            return
        }
        
        // REMOVED: Immediate sync when both streams start (was causing sync window gap)
        // Now we only sync after offset is calculated (above) or on timeout (pass-through fallback)
    }
    
    /// Find matching system audio for a given sample index with cross-buffer support
    /// Returns aligned samples starting at targetIndex
    private func findMatchingSystemAudio(
        forSampleIndex targetIndex: Int64,
        sampleCount: Int,
        in buffers: [IndexedBuffer]
    ) -> [Float]? {
        // Compute result first, then track statistics
        let result = findMatchingSystemAudioImpl(
            forSampleIndex: targetIndex,
            sampleCount: sampleCount,
            in: buffers
        )
        
        // Track match statistics (keeping per AGENTS.md)
        let matchFound = result != nil
        let logData: (shouldLog: Bool, hits: Int, total: Int, rate: Double) = Self.matchCounterLock.withLock { counters in
            if matchFound { counters.hits += 1 }
            else { counters.misses += 1 }
            let total = counters.hits + counters.misses
            // Log every 100th call to avoid performance impact
            if total % 100 == 0 {
                let rate = Double(counters.hits) / Double(total) * 100
                return (true, counters.hits, total, rate)
            }
            return (false, 0, 0, 0.0)
        }
        
        if logData.shouldLog {
            let matchMsg = "MATCH: \(logData.hits)/\(logData.total) (\(String(format: "%.1f", logData.rate))%)"
            Task { await DiagnosticLogger.shared.log(.aec, matchMsg) }
        }
        
        return result
    }
    
    /// Implementation of findMatchingSystemAudio (separated for statistics tracking)
    private func findMatchingSystemAudioImpl(
        forSampleIndex targetIndex: Int64,
        sampleCount: Int,
        in buffers: [IndexedBuffer]
    ) -> [Float]? {
        // Diagnostic: Log buffer range vs requested index (every 500th call)
        Self.lookupDiagCount += 1
        if Self.lookupDiagCount % 500 == 1 {
            let bufferRange: String
            if buffers.isEmpty {
                bufferRange = "empty"
            } else {
                let minIdx = buffers.first?.startSampleIndex ?? 0
                let maxIdx = (buffers.last?.startSampleIndex ?? 0) + Int64(buffers.last?.samples.count ?? 0)
                bufferRange = "\(minIdx)-\(maxIdx)"
            }
            let lookupMsg = "LOOKUP: target=\(targetIndex), buffers=\(bufferRange), count=\(buffers.count)"
            Task { await DiagnosticLogger.shared.log(.aec, lookupMsg) }
        }
        
        // Find buffer containing targetIndex
        for (index, buffer) in buffers.enumerated() {
            let bufferEndIndex = buffer.startSampleIndex + Int64(buffer.samples.count)
            if targetIndex >= buffer.startSampleIndex && targetIndex < bufferEndIndex {
                // Extract aligned samples starting at targetIndex
                let offset = Int(targetIndex - buffer.startSampleIndex)
                let available = buffer.samples.count - offset
                let count = min(available, sampleCount)
                
                var collectedSamples = Array(buffer.samples[offset..<(offset + count)])
                
                // Cross-buffer spanning: concatenate from subsequent buffers if needed
                if count < sampleCount {
                    var remainingNeeded = sampleCount - count
                    var nextIndex = index + 1
                    // Track accumulated end position, not fixed to first buffer
                    var accumulatedEndIndex = buffer.startSampleIndex + Int64(buffer.samples.count)
                    
                    while remainingNeeded > 0 && nextIndex < buffers.count {
                        let nextBuffer = buffers[nextIndex]
                        // Verify buffer continuity: next buffer should start where we ended
                        if nextBuffer.startSampleIndex == accumulatedEndIndex {
                            let takeFromNext = min(remainingNeeded, nextBuffer.samples.count)
                            collectedSamples.append(contentsOf: nextBuffer.samples[0..<takeFromNext])
                            remainingNeeded -= takeFromNext
                            // Update accumulated position for next iteration
                            accumulatedEndIndex = nextBuffer.startSampleIndex + Int64(takeFromNext)
                        } else {
                            // Gap in buffers - log warning and stop concatenating
                            let gapMsg = "BUFFER_GAP: expected=\(accumulatedEndIndex), got=\(nextBuffer.startSampleIndex)"
                            Task { await DiagnosticLogger.shared.log(.aec, gapMsg) }
                            break
                        }
                        nextIndex += 1
                    }
                    // If still incomplete, NLMS adapts to partial data (acceptable)
                }
                
                return collectedSamples
            }
        }
        
        // No buffer found - mic is ahead of system audio
        return nil
    }
    
    // MARK: - Test Accessors (internal for @testable import)
    
    /// Get buffer indices for verifying index continuity after gap fill
    /// Returns array of (start, end) sample indices for each buffer
    func getBufferIndices() -> [(start: Int64, end: Int64)] {
        state.withLock { state in
            state.systemAudioBuffers.map { buf in
                (buf.startSampleIndex, buf.startSampleIndex + Int64(buf.samples.count))
            }
        }
    }
    
    /// Get current system buffer count (for testing)
    var systemBufferCount: Int {
        state.withLock { $0.systemBufferCount }
    }
    
    /// Get total system samples (for testing)
    var totalSystemSamples: Int64 {
        state.withLock { $0.totalSystemSamples }
    }
    
    /// Get total gap samples filled (for testing)
    var totalGapSamples: Int64 {
        state.withLock { $0.totalGapSamples }
    }
    
    /// Get max gap size in samples (for testing)
    var maxGapSamples: Int64 {
        state.withLock { $0.maxGapSamples }
    }
    
    /// Get gap log count (for testing)
    var gapLogCount: Int {
        state.withLock { $0.gapLogCount }
    }
    
    /// Get current buffer count (for testing buffer pruning)
    var bufferCount: Int {
        state.withLock { $0.systemAudioBuffers.count }
    }
    
    /// Get bounds check fallback count (for testing offset validation fix)
    var boundsCheckFallbackCount: Int {
        state.withLock { $0.boundsCheckFallbackCount }
    }
    
    /// Get delivery offset in samples (for testing offset validation)
    var deliveryOffsetSamples: Int64 {
        state.withLock { $0.deliveryOffsetSamples }
    }
    
    /// Get total mic samples (for testing)
    var totalMicSamples: Int64 {
        state.withLock { $0.totalMicSamples }
    }
    
    /// Check if streams are synchronized (for testing)
    var streamsSynchronized: Bool {
        state.withLock { $0.streamsSynchronized }
    }
}
