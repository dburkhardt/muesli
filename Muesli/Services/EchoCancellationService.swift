import Foundation
import CoreMedia
import AVFoundation

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
        let isFloat = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        
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
            return Array(UnsafeBufferPointer(start: floatPointer, count: floatCount))
        } else {
            // Unsupported format
            return nil
        }
    }
    
    /// Create CMSampleBuffer from Float32 samples
    /// Converts from 48kHz Float32 mono to 16kHz Int16 stereo for file output
    /// - Parameters:
    ///   - samples: Float32 mono samples at source sample rate
    ///   - timestamp: Presentation timestamp for the buffer
    ///   - sourceSampleRate: Source sample rate (default: 48000)
    ///   - targetSampleRate: Target sample rate (default: 16000)
    /// - Returns: CMSampleBuffer in 16kHz Int16 stereo format, or nil if conversion fails
    static func createSampleBuffer(
        from samples: [Float],
        timestamp: CMTime,
        sourceSampleRate: Int = 48000,
        targetSampleRate: Int = 16000
    ) -> CMSampleBuffer? {
        guard !samples.isEmpty else { return nil }
        
        // 1. Resample from sourceSampleRate to targetSampleRate
        let resampled = resampleFloat32(
            samples: samples,
            sourceSampleRate: sourceSampleRate,
            targetSampleRate: targetSampleRate
        )
        
        guard !resampled.isEmpty else { return nil }
        
        // 2. Convert mono Float32 to stereo Int16 (duplicate channel)
        let stereoInt16: [Int16] = resampled.flatMap { sample in
            // Clamp and convert to Int16
            let clampedSample = max(-1.0, min(1.0, sample))
            let int16Value = Int16(clampedSample * 32767.0)
            return [int16Value, int16Value]  // Duplicate for stereo
        }
        
        // 3. Create AudioStreamBasicDescription for 16kHz Int16 stereo
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(targetSampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,  // 2 bytes per sample * 2 channels
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
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
        
        // 5. Create block buffer with the stereo Int16 data
        let dataSize = stereoInt16.count * MemoryLayout<Int16>.size
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
        
        // 6. Copy stereo Int16 data to block buffer
        status = stereoInt16.withUnsafeBufferPointer { bufferPtr in
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
    
    // MARK: - State
    
    /// Adaptive filter coefficients (weights)
    private var filterCoefficients: [Float]
    
    /// Buffer for reference signal (system audio)
    /// Used to predict echo in microphone signal
    private var referenceBuffer: [Float]
    
    /// Maximum delay to handle (in samples)
    /// This determines how much history we keep
    private let maxDelaySamples: Int
    
    /// Presentation timestamps for synchronization
    private struct TimestampedBuffer {
        let samples: [Float]
        let timestamp: CMTime
    }
    
    /// Buffers for system audio (reference signal) with timestamps
    private var systemAudioBuffers: [TimestampedBuffer] = []
    
    /// Lock for thread-safe access
    private let lock = NSLock()
    
    /// Maximum number of buffers to keep for synchronization
    private let maxBuffers: Int = 10
    
    // MARK: - Initialization
    
    /// Initialize echo cancellation service
    /// - Parameters:
    ///   - filterLength: Number of filter taps (default: 256)
    ///   - learningRate: Learning rate for adaptation (default: 0.3)
    ///   - sampleRate: Audio sample rate (default: 48000)
    ///   - maxDelayMs: Maximum echo delay to handle in milliseconds (default: 100ms)
    init(
        filterLength: Int = 256,
        learningRate: Float = 0.3,
        sampleRate: Int = 48000,
        maxDelayMs: Int = 100
    ) {
        self.filterLength = filterLength
        self.learningRate = learningRate
        self.sampleRate = sampleRate
        self.maxDelaySamples = (sampleRate * maxDelayMs) / 1000
        
        // Initialize filter coefficients to zero
        self.filterCoefficients = Array(repeating: 0.0, count: filterLength)
        
        // Initialize reference buffer
        self.referenceBuffer = Array(repeating: 0.0, count: filterLength)
    }
    
    // MARK: - Public API
    
    /// Store system audio as reference signal for echo cancellation
    /// - Parameters:
    ///   - systemSamples: System audio samples (reference signal - what's playing through speakers)
    ///   - timestamp: Presentation timestamp for system audio
    func storeSystemAudio(samples: [Float], timestamp: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        storeSystemAudioInternal(samples: samples, timestamp: timestamp)
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
        lock.lock()
        defer { lock.unlock() }
        
        // Find matching system audio for this microphone timestamp
        guard let referenceSamples = findMatchingSystemAudio(for: micTimestamp) else {
            // No matching system audio found, return microphone as-is
            return microphoneSamples
        }
        
        // Ensure reference buffer is long enough
        if referenceBuffer.count < filterLength {
            referenceBuffer = Array(repeating: 0.0, count: filterLength)
        }
        
        // Process samples using NLMS adaptive filter
        var outputSamples: [Float] = []
        outputSamples.reserveCapacity(microphoneSamples.count)
        
        for i in 0..<microphoneSamples.count {
            // Update reference buffer (shift and add new sample)
            if referenceSamples.count > i {
                // Shift buffer left
                referenceBuffer.removeFirst()
                referenceBuffer.append(referenceSamples[i])
            }
            
            // Compute predicted echo using current filter coefficients
            var predictedEcho: Float = 0.0
            for j in 0..<filterLength {
                let idx = referenceBuffer.count - filterLength + j
                if idx >= 0 && idx < referenceBuffer.count {
                    predictedEcho += filterCoefficients[j] * referenceBuffer[idx]
                }
            }
            
            // Compute error (microphone signal - predicted echo)
            let error = microphoneSamples[i] - predictedEcho
            
            // Update filter coefficients using NLMS algorithm
            // Compute power of reference signal
            var referencePower: Float = epsilon
            for j in 0..<filterLength {
                let idx = referenceBuffer.count - filterLength + j
                if idx >= 0 && idx < referenceBuffer.count {
                    referencePower += referenceBuffer[idx] * referenceBuffer[idx]
                }
            }
            
            // Update coefficients: w(n+1) = w(n) + μ * error * x(n) / (||x(n)||² + ε)
            let stepSize = learningRate / referencePower
            for j in 0..<filterLength {
                let idx = referenceBuffer.count - filterLength + j
                if idx >= 0 && idx < referenceBuffer.count {
                    filterCoefficients[j] += stepSize * error * referenceBuffer[idx]
                }
            }
            
            // Output is the error signal (microphone with echo removed)
            outputSamples.append(error)
        }
        
        return outputSamples
    }
    
    /// Reset filter state (call when starting new recording)
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        
        filterCoefficients = Array(repeating: 0.0, count: filterLength)
        referenceBuffer = Array(repeating: 0.0, count: filterLength)
        systemAudioBuffers.removeAll()
    }
    
    // MARK: - Private Helpers
    
    /// Store system audio buffer with timestamp (internal, assumes lock held)
    private func storeSystemAudioInternal(samples: [Float], timestamp: CMTime) {
        systemAudioBuffers.append(TimestampedBuffer(samples: samples, timestamp: timestamp))
        
        // Keep only recent buffers
        if systemAudioBuffers.count > maxBuffers {
            systemAudioBuffers.removeFirst()
        }
    }
    
    /// Find matching system audio for microphone timestamp
    /// Handles timing differences between system and microphone streams
    private func findMatchingSystemAudio(for micTimestamp: CMTime) -> [Float]? {
        // Find system audio buffer closest to microphone timestamp
        // Account for potential delay between system audio and microphone pickup
        
        guard !systemAudioBuffers.isEmpty else { return nil }
        
        // Find buffer with timestamp closest to microphone timestamp
        var bestMatch: TimestampedBuffer?
        var minTimeDiff = CMTime.positiveInfinity
        
        for buffer in systemAudioBuffers {
            let timeDiff = CMTimeSubtract(micTimestamp, buffer.timestamp)
            let absTimeDiff = CMTimeAbsoluteValue(timeDiff)
            
            if CMTimeCompare(absTimeDiff, minTimeDiff) < 0 {
                minTimeDiff = absTimeDiff
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
