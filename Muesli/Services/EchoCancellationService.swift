import AVFoundation
import CoreMedia
import Foundation
import os.lock

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
    private let maxBuffers: Int = 10
    
    /// Acoustic delay in samples (DAC + propagation + ADC latency)
    private let acousticDelaySamples: Int
    
    // MARK: - State (Thread-Safe via OSAllocatedUnfairLock)
    
    /// Presentation timestamps for synchronization
    private struct TimestampedBuffer {
        let samples: [Float]
        let timestamp: CMTime
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
    private struct AECState {
        var filterCoefficients: [Float]
        var referenceBuffer: CircularBuffer
        var systemAudioBuffers: [TimestampedBuffer]
    }
    
    /// Thread-safe state using OSAllocatedUnfairLock (AGENTS.md requirement)
    private let state: OSAllocatedUnfairLock<AECState>
    
    // MARK: - Initialization
    
    /// Initialize echo cancellation service
    /// - Parameters:
    ///   - filterLength: Number of filter taps (default: 256)
    ///   - learningRate: Learning rate for adaptation (default: 0.3)
    ///   - sampleRate: Audio sample rate (default: 48000)
    ///   - maxDelayMs: Maximum echo delay to handle in milliseconds (default: 100ms)
    ///   - acousticDelayMs: Acoustic delay (DAC + propagation + ADC) in milliseconds (default: 30ms)
    init(
        filterLength: Int = 256,
        learningRate: Float = 0.3,
        sampleRate: Int = 48000,
        maxDelayMs: Int = 100,
        acousticDelayMs: Int = AudioConfiguration.aecAcousticDelayMs
    ) {
        self.filterLength = filterLength
        self.learningRate = learningRate
        self.sampleRate = sampleRate
        self.maxDelaySamples = (sampleRate * maxDelayMs) / 1000
        self.acousticDelaySamples = (sampleRate * acousticDelayMs) / 1000
        
        // Calculate circular buffer capacity:
        // maxMicFrameSize (4096) + filterLength (256) + maxDelaySamples (4800) + bufferMargin (2400)
        // = ~11,552 samples → round to 12,000 (~250ms of audio history at 48kHz)
        let bufferCapacity = 12000
        
        self.state = OSAllocatedUnfairLock(initialState: AECState(
            filterCoefficients: Array(repeating: 0.0, count: filterLength),
            referenceBuffer: CircularBuffer(capacity: bufferCapacity),
            systemAudioBuffers: []
        ))
    }
    
    // MARK: - Public API
    
    /// Store system audio as reference signal for echo cancellation
    /// - Parameters:
    ///   - systemSamples: System audio samples (reference signal - what's playing through speakers)
    ///   - timestamp: Presentation timestamp for system audio
    func storeSystemAudio(samples: [Float], timestamp: CMTime) {
        state.withLock { state in
            state.systemAudioBuffers.append(TimestampedBuffer(samples: samples, timestamp: timestamp))
            
            // Keep only recent buffers - O(1) operation with circular indexing would be better
            // but for small maxBuffers (10), this is acceptable
            if state.systemAudioBuffers.count > maxBuffers {
                state.systemAudioBuffers.removeFirst()
            }
        }
    }
    
    /// Process microphone audio to remove echo
    /// - Parameters:
    ///   - microphoneSamples: Microphone audio samples (may contain echo)
    ///   - micTimestamp: Presentation timestamp for microphone audio
    /// - Returns: Clean microphone audio with echo removed
    func processMicrophoneAudio(
        microphoneSamples: [Float],
        micTimestamp: CMTime
    ) -> [Float] {
        state.withLock { state in
            // Find matching system audio for this microphone timestamp
            guard let referenceSamples = findMatchingSystemAudio(for: micTimestamp, in: state.systemAudioBuffers) else {
                // No matching system audio found, return microphone as-is
                // This is normal during warmup period (~250ms) - NLMS needs reference data
                return microphoneSamples
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
            
            return outputSamples
        }
    }
    
    /// Reset filter state (call when starting new recording)
    func reset() {
        state.withLock { state in
            state.filterCoefficients = Array(repeating: 0.0, count: filterLength)
            state.referenceBuffer.reset()
            state.systemAudioBuffers.removeAll()
        }
    }
    
    // MARK: - Private Helpers
    
    /// Find matching system audio for microphone timestamp
    /// Handles timing differences between system and microphone streams
    /// IMPORTANT: Only matches PAST system audio (timestamp <= micTimestamp) to avoid
    /// using future audio that hasn't been played through speakers yet
    private func findMatchingSystemAudio(for micTimestamp: CMTime, in buffers: [TimestampedBuffer]) -> [Float]? {
        guard !buffers.isEmpty else { return nil }
        
        // Filter to only PAST system audio (timestamp <= micTimestamp)
        // This ensures we never use audio that hasn't been played through speakers yet
        let validBuffers = buffers.filter { buffer in
            CMTimeCompare(buffer.timestamp, micTimestamp) <= 0
        }
        
        // Handle empty validBuffers edge case
        guard !validBuffers.isEmpty else {
            // No past system audio available yet - return nil (mic passes through unprocessed)
            // This is normal during warmup period (~250ms)
            return nil
        }
        
        // Find closest past buffer
        var bestMatch: TimestampedBuffer?
        var minTimeDiff = CMTime.positiveInfinity
        
        for buffer in validBuffers {
            let timeDiff = CMTimeSubtract(micTimestamp, buffer.timestamp)
            if CMTimeCompare(timeDiff, minTimeDiff) < 0 {
                minTimeDiff = timeDiff
                bestMatch = buffer
            }
        }
        
        // Only use if time difference is reasonable (within max delay)
        let maxDelayTime = CMTime(value: Int64(maxDelaySamples), timescale: CMTimeScale(sampleRate))
        if CMTimeCompare(minTimeDiff, maxDelayTime) <= 0 {
            return bestMatch?.samples
        }
        
        return nil
    }
}
