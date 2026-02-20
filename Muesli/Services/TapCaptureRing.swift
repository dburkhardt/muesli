//
//  TapCaptureRing.swift
//  Muesli
//
//  Lock-free ring buffer for render (system audio tap) packets.
//  Uses sample indices for pairing with capture ring.
//  RT-safe: No allocations during push/pop.
//

import Foundation
import os.lock

// MARK: - Timestamped Audio Packet

/// A packet of audio with sample index information
struct AudioPacket {
    /// Audio samples (Float32, interleaved if stereo)
    let samples: [Float]
    
    /// Starting sample index in the stream
    let startSampleIndex: Int64
    
    /// Sample time from AudioTimeStamp (if available)
    let sampleTime: Float64
    
    /// Host time from AudioTimeStamp
    let hostTime: UInt64
    
    /// Number of frames (samples / channels)
    var frameCount: Int { samples.count }
    
    /// End sample index (exclusive)
    var endSampleIndex: Int64 { startSampleIndex + Int64(samples.count) }
}

// MARK: - Tap Capture Ring (Render/System Audio)

/// Lock-free ring buffer for render (system audio tap) packets
/// Optimized for the tap audio pipeline where render arrives before capture.
///
/// Thread safety: Uses `os_unfair_lock` for minimal latency.
/// Memory: Pre-allocated capacity, no allocations during normal operation.
///
/// Sample-index based: Each packet is tagged with its stream position,
/// enabling precise pairing with capture packets.
final class TapCaptureRing {
    
    // MARK: - Configuration
    
    /// Default capacity: 600ms of audio at 48kHz (speakerphone mode max buffer)
    static let defaultCapacityMs: Int = 600
    
    /// Target render lead in samples (200ms at 48kHz)
    static let targetRenderLeadSamples: Int = 9600

    /// Allowed render lead band (100ms to 300ms at 48kHz)
    static let minRenderLeadSamples: Int = 4800
    static let maxRenderLeadSamples: Int = 14400
    
    // MARK: - Properties
    
    /// Pre-allocated sample buffer
    private var buffer: [Float]
    
    /// Capacity in samples
    let capacity: Int
    
    /// Write index (where next samples will be written)
    private var writeIndex: Int = 0
    
    /// Read index (where next samples will be read)
    private var readIndex: Int = 0
    
    /// Number of samples currently available
    private var count: Int = 0
    
    /// Starting sample index of the first available sample
    private var startSampleIndex: Int64 = 0
    
    /// Total samples written since last reset
    private var totalSamplesWritten: Int64 = 0
    
    /// Lock for thread safety
    private let lock = OSAllocatedUnfairLock()
    
    // MARK: - Discontinuity Detection
    
    /// Last sample time received (for discontinuity detection)
    private var lastSampleTime: Float64 = 0
    
    /// Expected samples per callback (for gap detection)
    private var expectedSamplesPerCallback: Int = 480  // 10ms at 48kHz
    
    /// Discontinuity threshold multiplier
    private let discontinuityMultiplier = 8
    
    /// Whether a discontinuity was detected since last reset
    private(set) var hasDiscontinuity: Bool = false

    private var callbackCount: Int = 0
    private let warmupCallbackCount: Int = 10        // ~100ms before detection activates
    private var debounceRemaining: Int = 0           // countdown after a detection fires
    private let debounceDuration: Int = 5            // ~50ms suppression after a detection

    // MARK: - Initialization
    
    /// Create a ring buffer with capacity in milliseconds
    /// - Parameters:
    ///   - capacityMs: Capacity in milliseconds
    ///   - sampleRate: Sample rate (default 48000)
    init(capacityMs: Int = defaultCapacityMs, sampleRate: Int = 48000) {
        self.capacity = capacityMs * sampleRate / 1000
        self.buffer = [Float](repeating: 0, count: capacity)
    }
    
    /// Create a ring buffer with capacity in samples
    /// - Parameter capacitySamples: Capacity in samples
    init(capacitySamples: Int) {
        self.capacity = capacitySamples
        self.buffer = [Float](repeating: 0, count: capacitySamples)
    }
    
    // MARK: - Public API
    
    /// Push samples into the ring buffer
    /// - Parameters:
    ///   - samples: Audio samples to push
    ///   - sampleTime: Sample time from AudioTimeStamp
    ///   - hostTime: Host time from AudioTimeStamp
    /// - Returns: True if samples were pushed (may have overwritten old data)
    @discardableResult
    func push(
        samples: UnsafePointer<Float>,
        count sampleCount: Int,
        sampleTime: Float64,
        hostTime: UInt64
    ) -> Bool {
        guard sampleCount > 0 else { return false }
        
        lock.lock()
        defer { lock.unlock() }
        
        // Check for discontinuity using sample time (skip if invalid: sentinel -1)
        if sampleTime >= 0 {
            callbackCount += 1
            if debounceRemaining > 0 {
                debounceRemaining -= 1
            }
            if lastSampleTime > 0 && callbackCount > warmupCallbackCount && debounceRemaining == 0 {
                let deltaSamples = sampleTime - lastSampleTime
                let threshold = Double(expectedSamplesPerCallback * discontinuityMultiplier)
                let negativeTolerance = -Double(expectedSamplesPerCallback) / 2.0  // -5ms

                if deltaSamples < negativeTolerance || deltaSamples > threshold {
                    hasDiscontinuity = true
                    debounceRemaining = debounceDuration
                }
            }
            lastSampleTime = sampleTime + Float64(sampleCount)
        }
        // When sampleTime < 0 (invalid), preserve lastSampleTime for next valid check
        
        // Handle overflow: drop oldest samples if needed
        let overflow = count + sampleCount - capacity
        if overflow > 0 {
            // Advance read index, dropping oldest samples
            readIndex = (readIndex + overflow) % capacity
            count -= overflow
            startSampleIndex += Int64(overflow)
        }
        
        // Write samples with wraparound
        let firstPart = min(sampleCount, capacity - writeIndex)
        let secondPart = sampleCount - firstPart
        
        // Copy first part
        for i in 0..<firstPart {
            buffer[writeIndex + i] = samples[i]
        }
        
        // Copy second part (wrapped)
        for i in 0..<secondPart {
            buffer[i] = samples[firstPart + i]
        }
        
        writeIndex = (writeIndex + sampleCount) % capacity
        count += sampleCount
        totalSamplesWritten += Int64(sampleCount)
        
        return true
    }
    
    /// Read samples at a specific sample index without consuming
    /// - Parameters:
    ///   - targetIndex: Sample index to read from
    ///   - count: Number of samples to read
    ///   - destination: Buffer to write samples to
    /// - Returns: True if samples were available at the target index
    func read(
        at targetIndex: Int64,
        count readCount: Int,
        into destination: UnsafeMutablePointer<Float>
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        // Check if target index is within available range
        let endSampleIndex = startSampleIndex + Int64(count)
        guard targetIndex >= startSampleIndex,
              targetIndex + Int64(readCount) <= endSampleIndex else {
            return false
        }
        
        // Calculate buffer offset
        let offsetFromStart = Int(targetIndex - startSampleIndex)
        let bufferStart = (readIndex + offsetFromStart) % capacity
        
        // Read with wraparound
        let firstPart = min(readCount, capacity - bufferStart)
        let secondPart = readCount - firstPart
        
        for i in 0..<firstPart {
            destination[i] = buffer[bufferStart + i]
        }
        
        for i in 0..<secondPart {
            destination[firstPart + i] = buffer[i]
        }
        
        return true
    }
    
    /// Pop and discard samples from the front of the buffer
    /// - Parameter count: Number of samples to discard
    /// - Returns: True if samples were discarded
    @discardableResult
    func discard(_ discardCount: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        guard discardCount <= count else { return false }
        
        readIndex = (readIndex + discardCount) % capacity
        count -= discardCount
        startSampleIndex += Int64(discardCount)
        
        return true
    }

    /// Pop samples from the front of the buffer.
    /// - Parameters:
    ///   - destination: Destination buffer for popped samples
    ///   - count: Number of samples to pop
    /// - Returns: True if enough samples were available
    func pop(
        into destination: UnsafeMutablePointer<Float>,
        count popCount: Int
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard popCount <= count else { return false }

        let firstPart = min(popCount, capacity - readIndex)
        let secondPart = popCount - firstPart

        for i in 0..<firstPart {
            destination[i] = buffer[readIndex + i]
        }

        for i in 0..<secondPart {
            destination[firstPart + i] = buffer[i]
        }

        readIndex = (readIndex + popCount) % capacity
        count -= popCount
        startSampleIndex += Int64(popCount)

        return true
    }
    
    /// Get the current available sample count
    var available: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    
    /// Get the current start sample index
    var currentStartIndex: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return startSampleIndex
    }
    
    /// Get the current end sample index (exclusive)
    var currentEndIndex: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return startSampleIndex + Int64(count)
    }
    
    /// Get total samples written since reset
    var totalWritten: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return totalSamplesWritten
    }
    
    /// Reset the buffer (clear all data)
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        
        writeIndex = 0
        readIndex = 0
        count = 0
        startSampleIndex = 0
        totalSamplesWritten = 0
        lastSampleTime = 0
        hasDiscontinuity = false
        callbackCount = 0
        debounceRemaining = 0
    }
    
    /// Clear discontinuity flag
    func clearDiscontinuity() {
        lock.lock()
        defer { lock.unlock() }
        hasDiscontinuity = false
    }
    
    /// Set expected samples per callback (for discontinuity detection)
    func setExpectedSamplesPerCallback(_ samples: Int) {
        lock.lock()
        defer { lock.unlock() }
        expectedSamplesPerCallback = samples
    }
}
