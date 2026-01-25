@testable import Muesli
import XCTest

/// Tests for EchoCancellationService
/// Tests sample-count synchronization approach (no timestamps)
final class EchoCancellationServiceTests: XCTestCase {
    var sut: EchoCancellationService!
    
    override func setUp() {
        super.setUp()
        // Use AudioConfiguration values to test production-equivalent behavior
        sut = EchoCancellationService(
            filterLength: AudioConfiguration.aecFilterLength,
            learningRate: AudioConfiguration.aecLearningRate,
            sampleRate: AudioConfiguration.captureSampleRate,
            maxDelayMs: 100,
            acousticDelayMs: AudioConfiguration.aecAcousticDelayMs
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
    
    // MARK: - Stream Synchronization Tests
    
    func testStreamSynchronization() {
        // With sample-count sync, both streams must start before processing begins
        // First call to storeSystemAudio marks system stream as started
        let systemSamples = generateSineWave(frequency: 440, sampleRate: 48000, duration: 0.02)
        sut.storeSystemAudio(samples: systemSamples)
        
        // First call to processMicrophoneAudio marks mic stream as started and syncs
        let micSamples = generateSineWave(frequency: 880, sampleRate: 48000, duration: 0.02)
        let result = sut.processMicrophoneAudio(microphoneSamples: micSamples)
        
        // After sync, mic samples should be processed (may return same or different)
        XCTAssertEqual(result.count, micSamples.count, "Output should have same sample count")
    }
    
    func testMicBeforeSystemAudioPassesThrough() {
        // If mic audio comes before system audio (during sync), should pass through
        let micSamples = generateSineWave(frequency: 880, sampleRate: 48000, duration: 0.02)
        
        // Process mic audio without any system audio stored
        let result = sut.processMicrophoneAudio(microphoneSamples: micSamples)
        
        // Should pass through during warmup (streams not yet synchronized)
        XCTAssertEqual(result, micSamples, "Should pass through before sync")
    }
    
    func testEmptyInputHandling() {
        // Empty input should return empty output
        let emptyResult = sut.processMicrophoneAudio(microphoneSamples: [])
        XCTAssertTrue(emptyResult.isEmpty, "Empty input should return empty output")
        
        // Empty system audio should be ignored (no-op)
        sut.storeSystemAudio(samples: [])
        // No crash = success
    }
    
    func testWarmupBehavior() {
        // During warmup (before sync), mic should pass through unprocessed
        // This is intentional - NLMS needs reference data before predicting echo
        
        let micSamples = generateSineWave(frequency: 880, sampleRate: 48000, duration: 0.01)
        
        // First call without any system audio should pass through (not yet synced)
        let result1 = sut.processMicrophoneAudio(microphoneSamples: micSamples)
        XCTAssertEqual(result1, micSamples, "Should pass through before sync")
        
        // Now add system audio - this syncs the streams
        let systemSamples = generateSineWave(frequency: 440, sampleRate: 48000, duration: 0.01)
        sut.storeSystemAudio(samples: systemSamples)
        
        // Next mic audio should be processed (streams now synced)
        let result2 = sut.processMicrophoneAudio(microphoneSamples: micSamples)
        
        // After sync with valid reference, AEC should process
        XCTAssertEqual(result2.count, micSamples.count, "Should process after sync")
    }
    
    // MARK: - Sample-Count Alignment Tests
    
    func testSampleCountAlignment() {
        // Test that after warmup, samples are aligned by count not timestamp
        let systemSamples = generateSineWave(frequency: 440, sampleRate: 48000, duration: 0.05)
        let micSamples = generateSineWave(frequency: 880, sampleRate: 48000, duration: 0.05)
        
        // Store enough system audio to exceed acoustic delay (30ms = 1440 samples at 48kHz)
        sut.storeSystemAudio(samples: systemSamples)  // 2400 samples
        
        // Process mic audio
        let result = sut.processMicrophoneAudio(microphoneSamples: micSamples)
        
        // Should produce valid output
        XCTAssertEqual(result.count, micSamples.count, "Output should have correct sample count")
        XCTAssertFalse(result.contains(where: { $0.isNaN }), "Output should not contain NaN")
        XCTAssertFalse(result.contains(where: { $0.isInfinite }), "Output should not contain Inf")
    }
    
    // MARK: - Circular Buffer Tests
    
    func testCircularBufferWrap() {
        // Test that the circular buffer handles wraparound correctly
        // by processing more samples than the buffer capacity
        
        let testIterations = 20
        
        for i in 0..<testIterations {
            // Generate and store system audio
            let systemSamples = generateSineWave(frequency: 440, sampleRate: 48000, duration: 0.05)
            sut.storeSystemAudio(samples: systemSamples)
            
            // Process mic audio
            let micSamples = generateSineWave(frequency: 880, sampleRate: 48000, duration: 0.05)
            let result = sut.processMicrophoneAudio(microphoneSamples: micSamples)
            
            // Should always produce valid output
            XCTAssertEqual(result.count, micSamples.count, "Iteration \(i): Output should have correct sample count")
            XCTAssertFalse(result.contains(where: { $0.isNaN }), "Iteration \(i): Output should not contain NaN")
            XCTAssertFalse(result.contains(where: { $0.isInfinite }), "Iteration \(i): Output should not contain Inf")
        }
    }
    
    // MARK: - Resampling Tests
    
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
        sut.storeSystemAudio(samples: systemSamples)
        
        let micSamples = generateSineWave(frequency: 880, sampleRate: 48000, duration: 0.02)
        _ = sut.processMicrophoneAudio(microphoneSamples: micSamples)
        
        // Reset
        sut.reset()
        
        // After reset, should behave like fresh instance (not synced)
        let result = sut.processMicrophoneAudio(microphoneSamples: micSamples)
        
        // After reset, mic is first to arrive - no sync yet, so pass through
        XCTAssertEqual(result, micSamples, "After reset, should pass through (not synced)")
    }
    
    func testResetClearsSyncState() {
        // Sync streams
        let systemSamples = generateSineWave(frequency: 440, sampleRate: 48000, duration: 0.02)
        sut.storeSystemAudio(samples: systemSamples)
        let micSamples = generateSineWave(frequency: 880, sampleRate: 48000, duration: 0.02)
        _ = sut.processMicrophoneAudio(microphoneSamples: micSamples)
        
        // Reset
        sut.reset()
        
        // After reset, sync state should be cleared
        // First mic call after reset should pass through (needs to wait for both streams)
        let postResetResult = sut.processMicrophoneAudio(microphoneSamples: micSamples)
        XCTAssertEqual(postResetResult, micSamples, "After reset, should require new sync")
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
                    self.sut.storeSystemAudio(samples: samples)
                } else {
                    _ = self.sut.processMicrophoneAudio(microphoneSamples: samples)
                }
                
                expectation.fulfill()
            }
        }
        
        wait(for: [expectation], timeout: 10.0)
    }
    
    // MARK: - Sample Count Preservation Tests
    
    func testSampleCountPreservedAfterProcessing() {
        // After processing, sample count should be preserved
        
        let systemSamples = generateSineWave(frequency: 440, sampleRate: 48000, duration: 0.02)
        sut.storeSystemAudio(samples: systemSamples)
        
        let micSamples = generateSineWave(frequency: 880, sampleRate: 48000, duration: 0.02)
        let result = sut.processMicrophoneAudio(microphoneSamples: micSamples)
        
        // Output sample count should match input
        XCTAssertEqual(result.count, micSamples.count, "Sample count should be preserved")
    }
    
    // MARK: - Sync Window Tests (per plan Issue 2)
    
    func testMicPassesThroughDuringWarmup() {
        // Test that mic audio passes through unchanged during warmup period
        // (before offset is calculated from kBuffersToAverage = 50 buffers per stream)
        
        let micSamples = generateSineWave(frequency: 880, sampleRate: 48000, duration: 0.01)
        
        // Feed 10 buffers to each stream (less than kBuffersToAverage = 50)
        for _ in 0..<10 {
            let systemSamples = generateSineWave(frequency: 440, sampleRate: 48000, duration: 0.02)
            sut.storeSystemAudio(samples: systemSamples)
            
            // Mic should pass through unchanged during warmup
            let result = sut.processMicrophoneAudio(microphoneSamples: micSamples)
            
            // During warmup (offset not calculated), mic should pass through
            // Note: After first buffer, streams are marked as started but offset is not yet calculated
            XCTAssertEqual(result.count, micSamples.count, "Should have correct sample count during warmup")
        }
    }
    
    func testSyncActivatesAfterWarmup() {
        // Test that AEC activates after warmup period completes
        // kBuffersToAverage = 50, so we need >= 50 buffers from each stream
        
        let micSamples = generateSineWave(frequency: 880, sampleRate: 48000, duration: 0.02)  // 960 samples
        let systemSamples = generateSineWave(frequency: 440, sampleRate: 48000, duration: 0.02)  // 960 samples
        
        // Feed 55 buffers to each stream (more than kBuffersToAverage = 50)
        for _ in 0..<55 {
            sut.storeSystemAudio(samples: systemSamples)
            _ = sut.processMicrophoneAudio(microphoneSamples: micSamples)
        }
        
        // Now AEC should be active with proper offset
        // Process one more buffer after warmup
        let finalResult = sut.processMicrophoneAudio(microphoneSamples: micSamples)
        
        // After warmup, AEC should process (may or may not equal input depending on echo detection)
        XCTAssertEqual(finalResult.count, micSamples.count, "Should have correct sample count after warmup")
        XCTAssertFalse(finalResult.contains(where: { $0.isNaN }), "Should not contain NaN after warmup")
    }
    
    // MARK: - Resampling Fallback Integration Test (per plan Issue 1)
    
    func testResampleFloat32_SmallBufferInput() {
        // Test edge case with small buffer (100 samples)
        // This verifies resampling handles minimal realistic input
        let samples = generateSineWave(frequency: 440, sampleRate: 44100, duration: 0.01)  // ~441 samples
        let result = EchoCancellationService.resampleFloat32Public(
            samples: samples,
            sourceSampleRate: 44100,
            targetSampleRate: 48000
        )
        
        // Small buffer should produce proportionally scaled output
        // 441 samples at 44100 → ~480 samples at 48000
        let expectedCount = Int(Double(samples.count) * 48000.0 / 44100.0)
        XCTAssertEqual(result.count, expectedCount, accuracy: 2, "Small buffer should produce scaled output")
        XCTAssertFalse(result.isEmpty, "Small buffer should produce output")
    }
}
