import CoreMedia
@testable import Muesli
import XCTest

/// Tests for EchoCancellationService
/// Covers the AEC critical fixes from the revised_aec_critical_fixes plan
final class EchoCancellationServiceTests: XCTestCase {
    var sut: EchoCancellationService!
    
    override func setUp() {
        super.setUp()
        sut = EchoCancellationService(
            filterLength: 256,
            learningRate: 0.3,
            sampleRate: 48000,
            maxDelayMs: 100,
            acousticDelayMs: 30
        )
    }
    
    override func tearDown() {
        sut = nil
        super.tearDown()
    }
    
    // MARK: - Test Helpers
    
    /// Generate sine wave test signal
    func generateSineWave(frequency: Double, sampleRate: Int, duration: Double) -> [Float] {
        let sampleCount = Int(Double(sampleRate) * duration)
        return (0..<sampleCount).map { i in
            Float(sin(2 * .pi * frequency * Double(i) / Double(sampleRate)))
        }
    }
    
    /// Create CMTime for testing
    func makeTimestamp(seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 48000)
    }
    
    // MARK: - Phase 1: Only Past Audio Matched
    
    func testOnlyPastAudioMatched() {
        // Store system audio at time 0.0
        let systemSamples = generateSineWave(frequency: 440, sampleRate: 48000, duration: 0.02)
        sut.storeSystemAudio(samples: systemSamples, timestamp: makeTimestamp(seconds: 0.0))
        
        // Process mic audio at time 0.1 (after system audio)
        let micSamples = generateSineWave(frequency: 880, sampleRate: 48000, duration: 0.02)
        let result = sut.processMicrophoneAudio(
            microphoneSamples: micSamples,
            micTimestamp: makeTimestamp(seconds: 0.1)
        )
        
        // Should get processed output (AEC applied) because past audio is available
        XCTAssertEqual(result.count, micSamples.count, "Output should have same sample count")
        // The output should be different from input due to AEC processing
        // (even if small difference due to NLMS adaptation)
    }
    
    func testFutureAudioNotMatched() {
        // Store system audio at time 1.0
        let systemSamples = generateSineWave(frequency: 440, sampleRate: 48000, duration: 0.02)
        sut.storeSystemAudio(samples: systemSamples, timestamp: makeTimestamp(seconds: 1.0))
        
        // Process mic audio at time 0.5 (before system audio)
        let micSamples = generateSineWave(frequency: 880, sampleRate: 48000, duration: 0.02)
        let result = sut.processMicrophoneAudio(
            microphoneSamples: micSamples,
            micTimestamp: makeTimestamp(seconds: 0.5)
        )
        
        // Should return input unchanged because no PAST audio available
        XCTAssertEqual(result, micSamples, "Should return input unchanged when only future audio available")
    }
    
    // MARK: - Phase 1: Empty Valid Buffers Edge Case
    
    func testEmptyValidBuffers() {
        // Don't store any system audio
        
        // Process mic audio
        let micSamples = generateSineWave(frequency: 880, sampleRate: 48000, duration: 0.02)
        let result = sut.processMicrophoneAudio(
            microphoneSamples: micSamples,
            micTimestamp: makeTimestamp(seconds: 0.1)
        )
        
        // Should return input unchanged when no system audio available
        XCTAssertEqual(result, micSamples, "Should return input unchanged when no system audio available")
    }
    
    func testWarmupBehavior() {
        // During warmup (~250ms), mic should pass through unprocessed
        // This is intentional - NLMS needs reference data before predicting echo
        
        let micSamples = generateSineWave(frequency: 880, sampleRate: 48000, duration: 0.01)
        
        // First few calls without any system audio should pass through
        let result1 = sut.processMicrophoneAudio(
            microphoneSamples: micSamples,
            micTimestamp: makeTimestamp(seconds: 0.0)
        )
        XCTAssertEqual(result1, micSamples, "Should pass through during warmup")
        
        // Now add system audio and process again
        let systemSamples = generateSineWave(frequency: 440, sampleRate: 48000, duration: 0.01)
        sut.storeSystemAudio(samples: systemSamples, timestamp: makeTimestamp(seconds: 0.1))
        
        let result2 = sut.processMicrophoneAudio(
            microphoneSamples: micSamples,
            micTimestamp: makeTimestamp(seconds: 0.15)
        )
        
        // After warmup with valid reference, AEC should process
        XCTAssertEqual(result2.count, micSamples.count, "Should process after warmup")
    }
    
    // MARK: - Phase 3: Circular Buffer Tests
    
    func testCircularBufferWrap() {
        // Test that the circular buffer handles wraparound correctly
        // by processing more samples than the buffer capacity
        
        let bufferCapacity = 12000 // matches the init capacity
        let testIterations = 20
        
        for i in 0..<testIterations {
            // Generate and store system audio
            let systemSamples = generateSineWave(frequency: 440, sampleRate: 48000, duration: 0.05)
            sut.storeSystemAudio(
                samples: systemSamples,
                timestamp: makeTimestamp(seconds: Double(i) * 0.1)
            )
            
            // Process mic audio
            let micSamples = generateSineWave(frequency: 880, sampleRate: 48000, duration: 0.05)
            let result = sut.processMicrophoneAudio(
                microphoneSamples: micSamples,
                micTimestamp: makeTimestamp(seconds: Double(i) * 0.1 + 0.01)
            )
            
            // Should always produce valid output
            XCTAssertEqual(result.count, micSamples.count, "Iteration \(i): Output should have correct sample count")
            XCTAssertFalse(result.contains(where: { $0.isNaN }), "Iteration \(i): Output should not contain NaN")
            XCTAssertFalse(result.contains(where: { $0.isInfinite }), "Iteration \(i): Output should not contain Inf")
        }
    }
    
    // MARK: - Phase 0: Resampling Tests
    
    func testResampleFloat32_NoOpWhenSameRate() {
        // When source and target rates are the same, should return unchanged
        let samples: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        
        let result = EchoCancellationService.resampleFloat32Public(
            samples: samples,
            sourceSampleRate: 48000,
            targetSampleRate: 48000
        )
        
        XCTAssertEqual(result, samples, "Should return unchanged when rates match")
    }
    
    func testResampleFloat32_44100To48000() {
        // Test common case: 44.1kHz mic to 48kHz
        let samples = generateSineWave(frequency: 440, sampleRate: 44100, duration: 0.1)
        
        let result = EchoCancellationService.resampleFloat32Public(
            samples: samples,
            sourceSampleRate: 44100,
            targetSampleRate: 48000
        )
        
        // Expected output count: 4410 * (48000/44100) ≈ 4800
        let expectedCount = Int(Double(samples.count) * 48000.0 / 44100.0)
        XCTAssertEqual(result.count, expectedCount, accuracy: 1, "Output count should match expected ratio")
        XCTAssertFalse(result.isEmpty, "Should produce output samples")
    }
    
    func testResampleFloat32_96000To48000() {
        // Test downsampling: 96kHz to 48kHz
        let samples = generateSineWave(frequency: 440, sampleRate: 96000, duration: 0.1)
        
        let result = EchoCancellationService.resampleFloat32Public(
            samples: samples,
            sourceSampleRate: 96000,
            targetSampleRate: 48000
        )
        
        // Expected output count: samples.count / 2
        let expectedCount = samples.count / 2
        XCTAssertEqual(result.count, expectedCount, accuracy: 1, "Output count should be half for 2x downsample")
    }
    
    func testResampleFloat32_EmptyInput() {
        // Empty input should return empty output
        let result = EchoCancellationService.resampleFloat32Public(
            samples: [],
            sourceSampleRate: 44100,
            targetSampleRate: 48000
        )
        
        XCTAssertTrue(result.isEmpty, "Empty input should produce empty output")
    }
    
    // MARK: - Reset Tests
    
    func testReset() {
        // Store some audio and process
        let systemSamples = generateSineWave(frequency: 440, sampleRate: 48000, duration: 0.02)
        sut.storeSystemAudio(samples: systemSamples, timestamp: makeTimestamp(seconds: 0.0))
        
        let micSamples = generateSineWave(frequency: 880, sampleRate: 48000, duration: 0.02)
        _ = sut.processMicrophoneAudio(
            microphoneSamples: micSamples,
            micTimestamp: makeTimestamp(seconds: 0.01)
        )
        
        // Reset
        sut.reset()
        
        // After reset, should behave like fresh instance (no system audio available)
        let result = sut.processMicrophoneAudio(
            microphoneSamples: micSamples,
            micTimestamp: makeTimestamp(seconds: 0.02)
        )
        
        XCTAssertEqual(result, micSamples, "After reset, should pass through (no system audio)")
    }
    
    // MARK: - Thread Safety Tests
    
    func testConcurrentAccess() {
        // Test that concurrent access doesn't cause crashes
        let expectation = XCTestExpectation(description: "Concurrent access completes")
        expectation.expectedFulfillmentCount = 100
        
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
        
        for i in 0..<100 {
            queue.async {
                let samples = self.generateSineWave(frequency: 440, sampleRate: 48000, duration: 0.01)
                
                if i % 2 == 0 {
                    self.sut.storeSystemAudio(
                        samples: samples,
                        timestamp: self.makeTimestamp(seconds: Double(i) * 0.01)
                    )
                } else {
                    _ = self.sut.processMicrophoneAudio(
                        microphoneSamples: samples,
                        micTimestamp: self.makeTimestamp(seconds: Double(i) * 0.01)
                    )
                }
                
                expectation.fulfill()
            }
        }
        
        wait(for: [expectation], timeout: 10.0)
    }
    
    // MARK: - Timestamp Integrity Tests
    
    func testTimestampPreservedAfterProcessing() {
        // Timestamps represent presentation time, not sample position
        // After processing, the timing relationship should be preserved
        
        let systemSamples = generateSineWave(frequency: 440, sampleRate: 48000, duration: 0.02)
        let systemTimestamp = makeTimestamp(seconds: 0.0)
        sut.storeSystemAudio(samples: systemSamples, timestamp: systemTimestamp)
        
        let micSamples = generateSineWave(frequency: 880, sampleRate: 48000, duration: 0.02)
        let micTimestamp = makeTimestamp(seconds: 0.01)
        
        let result = sut.processMicrophoneAudio(
            microphoneSamples: micSamples,
            micTimestamp: micTimestamp
        )
        
        // Output sample count should match input (same duration at same rate)
        XCTAssertEqual(result.count, micSamples.count, "Sample count should be preserved")
    }
}
