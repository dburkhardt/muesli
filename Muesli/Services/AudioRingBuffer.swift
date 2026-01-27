import Foundation

/// Pre-allocated ring buffer for real-time audio processing
/// No allocations in push/pop operations (index-based, not Array operations)
///
/// Design notes:
/// - Uses a fixed-size pre-allocated array to avoid heap allocations during audio processing
/// - Index-based access for O(1) operations
/// - Handles wraparound correctly for both read and write operations
/// - Overflow behavior: overwrites oldest samples when full (sliding window)
struct AudioRingBuffer {
    private var buffer: [Float]
    private var writeIndex: Int = 0
    private var readIndex: Int = 0
    private var count: Int = 0
    let capacity: Int
    
    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [Float](repeating: 0, count: capacity)
    }
    
    /// Push samples, overwriting oldest if full (sliding window behavior)
    /// Uses withUnsafeBufferPointer for zero-allocation iteration (real-time safe)
    mutating func push(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { ptr in
            for i in 0..<ptr.count {
                if count >= capacity {
                    // Buffer full: advance readIndex (drop oldest) before writing
                    readIndex = (readIndex + 1) % capacity
                } else {
                    count += 1
                }
                buffer[writeIndex] = ptr[i]
                writeIndex = (writeIndex + 1) % capacity
            }
        }
    }
    
    /// Push samples from a pre-allocated buffer (no allocation)
    mutating func push(_ samples: UnsafeBufferPointer<Float>, count sampleCount: Int) {
        let countToWrite = min(sampleCount, samples.count)
        for i in 0..<countToWrite {
            if count >= capacity {
                readIndex = (readIndex + 1) % capacity
            } else {
                count += 1
            }
            buffer[writeIndex] = samples[i]
            writeIndex = (writeIndex + 1) % capacity
        }
    }
    
    /// Pop samples into a pre-allocated buffer (zero allocation)
    /// Handles wraparound correctly
    mutating func popInto(_ destination: UnsafeMutableBufferPointer<Float>, count requestedCount: Int) -> Bool {
        guard requestedCount <= self.count, requestedCount <= destination.count else { return false }
        
        // Handle wraparound: if readIndex + count exceeds capacity, wrap to start
        if readIndex + requestedCount <= capacity {
            // Simple case: no wraparound
            for i in 0..<requestedCount {
                destination[i] = buffer[readIndex + i]
            }
        } else {
            // Wraparound: read from readIndex to end, then from start
            let firstPart = capacity - readIndex
            for i in 0..<firstPart {
                destination[i] = buffer[readIndex + i]
            }
            for i in 0..<(requestedCount - firstPart) {
                destination[firstPart + i] = buffer[i]
            }
        }
        
        readIndex = (readIndex + requestedCount) % capacity
        self.count -= requestedCount
        return true
    }

    /// Pop samples into an array (uses UnsafeMutableBufferPointer internally)
    mutating func popIntoArray(_ destination: inout [Float], count requestedCount: Int) -> Bool {
        return destination.withUnsafeMutableBufferPointer { ptr in
            popInto(ptr, count: requestedCount)
        }
    }
    
    /// Pop and discard samples (for consumption without copying)
    mutating func discard(_ discardCount: Int) -> Bool {
        guard discardCount <= self.count else { return false }
        readIndex = (readIndex + discardCount) % capacity
        self.count -= discardCount
        return true
    }
    
    /// Read samples at offset without consuming (for alignment lookup)
    /// Handles wraparound correctly
    func read(at offset: Int, count readCount: Int, into destination: UnsafeMutableBufferPointer<Float>) -> Bool {
        guard offset >= 0, offset + readCount <= self.count, readCount <= destination.count else { return false }
        
        let startIdx = (readIndex + offset) % capacity
        
        // Handle wraparound: if startIdx + count exceeds capacity, wrap to start
        if startIdx + readCount <= capacity {
            // Simple case: no wraparound
            for i in 0..<readCount {
                destination[i] = buffer[startIdx + i]
            }
        } else {
            // Wraparound: read from startIdx to end, then from start
            let firstPart = capacity - startIdx
            for i in 0..<firstPart {
                destination[i] = buffer[startIdx + i]
            }
            for i in 0..<(readCount - firstPart) {
                destination[firstPart + i] = buffer[i]
            }
        }
        
        return true
    }
    
    /// Number of samples currently available in the buffer
    var available: Int { count }
    
    /// Clear all samples from the buffer
    mutating func clear() {
        writeIndex = 0
        readIndex = 0
        count = 0
    }
}
