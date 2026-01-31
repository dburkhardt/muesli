//
//  MicCaptureRing.swift
//  Muesli
//
//  Lock-free ring buffer for capture (microphone) packets.
//  Uses sample indices for pairing with render ring.
//  RT-safe: No allocations during push/pop.
//

import Foundation
import os.lock

// MARK: - Mic Capture Ring

/// Lock-free ring buffer for capture (microphone) packets
/// Similar to TapCaptureRing but with capture-specific policies.
///
/// Thread safety: Uses `os_unfair_lock` for minimal latency.
/// Memory: Pre-allocated capacity, no allocations during normal operation.
///
/// Sample-index based: Each packet is tagged with its stream position,
/// enabling precise pairing with render packets.
final class MicCaptureRing {
    
    // MARK: - Configuration
    
    /// Default capacity: 250ms of audio at 48kHz (capture max per plan)
    static let defaultCapacityMs: Int = 250
    
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
    
    // MARK: - Overflow Tracking
    
    /// Number of times the buffer overflowed (capture grew too large)
    private var overflowCount: Int = 0
    
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
    /// Per plan: If capture > max, trigger discontinuity reset
    /// - Parameters:
    ///   - samples: Audio samples to push
    ///   - sampleTime: Sample time from AudioTimeStamp
    ///   - hostTime: Host time from AudioTimeStamp
    /// - Returns: True if samples were pushed, false if overflow triggered discontinuity
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
        
        // Check for discontinuity using sample time
        if lastSampleTime > 0 {
            let deltaSamples = sampleTime - lastSampleTime
            let threshold = Double(expectedSamplesPerCallback * discontinuityMultiplier)
            
            if deltaSamples <= 0 || deltaSamples > threshold {
                hasDiscontinuity = true
            }
        }
        lastSampleTime = sampleTime + Float64(sampleCount)
        
        // Check for overflow (capture grew too large = alignment broken)
        if count + sampleCount > capacity {
            hasDiscontinuity = true
            overflowCount += 1
            
            // Clear buffer and start fresh
            writeIndex = 0
            readIndex = 0
            count = 0
            startSampleIndex = totalSamplesWritten
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
        
        return !hasDiscontinuity
    }
    
    /// Pop samples from the front of the buffer
    /// - Parameters:
    ///   - destination: Buffer to write samples to
    ///   - count: Number of samples to pop
    /// - Returns: True if samples were available
    func pop(
        into destination: UnsafeMutablePointer<Float>,
        count popCount: Int
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        guard popCount <= count else { return false }
        
        // Read with wraparound
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
    
    /// Pop samples as an array
    /// - Parameter count: Number of samples to pop
    /// - Returns: Array of samples, or nil if not enough available
    func popArray(count popCount: Int) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        
        guard popCount <= count else { return nil }
        
        var result = [Float](repeating: 0, count: popCount)
        
        // Read with wraparound
        let firstPart = min(popCount, capacity - readIndex)
        let secondPart = popCount - firstPart
        
        for i in 0..<firstPart {
            result[i] = buffer[readIndex + i]
        }
        
        for i in 0..<secondPart {
            result[firstPart + i] = buffer[i]
        }
        
        readIndex = (readIndex + popCount) % capacity
        count -= popCount
        startSampleIndex += Int64(popCount)
        
        return result
    }
    
    /// Read samples without consuming (peek)
    /// - Parameters:
    ///   - destination: Buffer to write samples to
    ///   - count: Number of samples to peek
    /// - Returns: True if samples were available
    func peek(
        into destination: UnsafeMutablePointer<Float>,
        count peekCount: Int
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        guard peekCount <= count else { return false }
        
        // Read with wraparound
        let firstPart = min(peekCount, capacity - readIndex)
        let secondPart = peekCount - firstPart
        
        for i in 0..<firstPart {
            destination[i] = buffer[readIndex + i]
        }
        
        for i in 0..<secondPart {
            destination[firstPart + i] = buffer[i]
        }
        
        return true
    }
    
    /// Discard samples from the front of the buffer
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
    
    /// Get overflow count
    var overflows: Int {
        lock.lock()
        defer { lock.unlock() }
        return overflowCount
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
        overflowCount = 0
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
