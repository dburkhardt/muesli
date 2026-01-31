//
//  CoreAudioTapTests.swift
//  MuesliTests
//
//  Unit tests for the Core Audio Tap architecture.
//  Tests ring buffers, synchronizer, delay controller, and drift tracker.
//

import XCTest
@testable import Muesli

final class CoreAudioTapTests: XCTestCase {
    
    // MARK: - TapCaptureRing Tests
    
    func testTapCaptureRingBasicPushPop() {
        let ring = TapCaptureRing(capacityMs: 100, sampleRate: 48000)  // 4800 samples
        
        // Push 480 samples (10ms)
        let samples = [Float](repeating: 0.5, count: 480)
        samples.withUnsafeBufferPointer { ptr in
            ring.push(samples: ptr.baseAddress!, count: 480, sampleTime: 0, hostTime: 0)
        }
        
        XCTAssertEqual(ring.available, 480)
        XCTAssertEqual(ring.currentStartIndex, 0)
        XCTAssertEqual(ring.currentEndIndex, 480)
    }
    
    func testTapCaptureRingOverflow() {
        let ring = TapCaptureRing(capacitySamples: 1000)
        
        // Push 800 samples
        let samples1 = [Float](repeating: 0.25, count: 800)
        samples1.withUnsafeBufferPointer { ptr in
            ring.push(samples: ptr.baseAddress!, count: 800, sampleTime: 0, hostTime: 0)
        }
        
        XCTAssertEqual(ring.available, 800)
        
        // Push 400 more (overflow by 200)
        let samples2 = [Float](repeating: 0.75, count: 400)
        samples2.withUnsafeBufferPointer { ptr in
            ring.push(samples: ptr.baseAddress!, count: 400, sampleTime: 800, hostTime: 0)
        }
        
        // Should have dropped oldest 200 samples
        XCTAssertEqual(ring.available, 1000)
        XCTAssertEqual(ring.currentStartIndex, 200)
        XCTAssertEqual(ring.currentEndIndex, 1200)
    }
    
    func testTapCaptureRingReadAtIndex() {
        let ring = TapCaptureRing(capacitySamples: 1000)
        
        // Push samples with known pattern
        var samples = [Float](repeating: 0, count: 500)
        for i in 0..<500 {
            samples[i] = Float(i)
        }
        
        samples.withUnsafeBufferPointer { ptr in
            ring.push(samples: ptr.baseAddress!, count: 500, sampleTime: 0, hostTime: 0)
        }
        
        // Read 100 samples starting at index 200
        var readBuffer = [Float](repeating: 0, count: 100)
        let success = readBuffer.withUnsafeMutableBufferPointer { ptr in
            ring.read(at: 200, count: 100, into: ptr.baseAddress!)
        }
        
        XCTAssertTrue(success)
        XCTAssertEqual(readBuffer[0], 200)
        XCTAssertEqual(readBuffer[99], 299)
    }
    
    func testTapCaptureRingDiscard() {
        let ring = TapCaptureRing(capacitySamples: 1000)
        
        let samples = [Float](repeating: 1.0, count: 500)
        samples.withUnsafeBufferPointer { ptr in
            ring.push(samples: ptr.baseAddress!, count: 500, sampleTime: 0, hostTime: 0)
        }
        
        ring.discard(200)
        
        XCTAssertEqual(ring.available, 300)
        XCTAssertEqual(ring.currentStartIndex, 200)
    }
    
    // MARK: - MicCaptureRing Tests
    
    func testMicCaptureRingBasicPushPop() {
        let ring = MicCaptureRing(capacitySamples: 1000)
        
        let samples = [Float](repeating: 0.5, count: 480)
        samples.withUnsafeBufferPointer { ptr in
            ring.push(samples: ptr.baseAddress!, count: 480, sampleTime: 0, hostTime: 0)
        }
        
        XCTAssertEqual(ring.available, 480)
        
        // Pop samples
        let popped = ring.popArray(count: 240)
        XCTAssertNotNil(popped)
        XCTAssertEqual(popped?.count, 240)
        XCTAssertEqual(ring.available, 240)
    }
    
    func testMicCaptureRingOverflowTriggersDiscontinuity() {
        let ring = MicCaptureRing(capacitySamples: 1000)
        
        // Fill buffer
        let samples1 = [Float](repeating: 0.5, count: 1000)
        samples1.withUnsafeBufferPointer { ptr in
            ring.push(samples: ptr.baseAddress!, count: 1000, sampleTime: 0, hostTime: 0)
        }
        
        XCTAssertFalse(ring.hasDiscontinuity)
        
        // Overflow - should trigger discontinuity
        let samples2 = [Float](repeating: 0.5, count: 100)
        samples2.withUnsafeBufferPointer { ptr in
            ring.push(samples: ptr.baseAddress!, count: 100, sampleTime: 1000, hostTime: 0)
        }
        
        XCTAssertTrue(ring.hasDiscontinuity)
    }
    
    // MARK: - CoarseDelayController Tests
    
    func testCoarseDelayControllerHysteresis() {
        let controller = CoarseDelayController()
        
        // Update with delay within deadband (< 720 samples = 15ms)
        controller.update(observedDelaySamples: 500)
        controller.update(observedDelaySamples: 600)
        
        // Should not have changed significantly
        XCTAssertLessThan(controller.currentDelaySamples, 50)
        
        // Update with delay outside deadband
        controller.update(observedDelaySamples: 5000)
        
        // Should start moving toward target
        XCTAssertGreaterThan(controller.currentDelaySamples, 0)
    }
    
    func testCoarseDelayControllerClamp() {
        let controller = CoarseDelayController()
        
        // Try to set delay beyond max (500ms = 24000 samples)
        controller.update(observedDelaySamples: 30000)
        
        // Wait for slewing (simulate time passing)
        for _ in 0..<100 {
            controller.update(observedDelaySamples: 30000)
        }
        
        // Should be clamped to max
        XCTAssertLessThanOrEqual(controller.currentDelaySamples, 24000)
    }
    
    func testCoarseDelayControllerFreezeAdaptation() {
        let controller = CoarseDelayController()
        
        controller.update(observedDelaySamples: 5000)
        let delayBefore = controller.currentDelaySamples
        
        controller.freezeAdaptation()
        controller.update(observedDelaySamples: 10000)
        
        // Should not have changed
        XCTAssertEqual(controller.currentDelaySamples, delayBefore)
        
        controller.unfreezeAdaptation()
    }
    
    // MARK: - DriftTracker Tests
    
    func testDriftTrackerInitialState() {
        let tracker = DriftTracker()
        
        XCTAssertEqual(tracker.currentDriftPPM, 0)
        XCTAssertFalse(tracker.hasValidEstimate)
        XCTAssertEqual(tracker.resampleRatio, 1.0)
    }
    
    func testDriftTrackerReset() {
        let tracker = DriftTracker()
        
        // Add some data
        for i in 0..<10 {
            tracker.updateRender(sampleTime: Double(i * 480), hostTime: UInt64(i) * 10_000_000, sampleCount: 480)
            tracker.updateCapture(sampleTime: Double(i * 480), hostTime: UInt64(i) * 10_000_000, sampleCount: 480)
        }
        
        tracker.reset()
        
        XCTAssertEqual(tracker.currentDriftPPM, 0)
        XCTAssertFalse(tracker.hasValidEstimate)
    }
    
    // MARK: - AdaptiveResampler Tests
    
    func testAdaptiveResamplerNoChange() {
        let input: [Float] = [1.0, 2.0, 3.0, 4.0, 5.0]
        let output = AdaptiveResampler.resample(input: input, ratio: 1.0)
        
        XCTAssertEqual(output, input)
    }
    
    func testAdaptiveResamplerSpeedUp() {
        let input: [Float] = [1.0, 2.0, 3.0, 4.0]
        let output = AdaptiveResampler.resample(input: input, ratio: 2.0)
        
        // Output should be longer
        XCTAssertEqual(output.count, 8)
    }
    
    func testAdaptiveResamplerSlowDown() {
        let input: [Float] = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]
        let output = AdaptiveResampler.resample(input: input, ratio: 0.5)
        
        // Output should be shorter
        XCTAssertEqual(output.count, 3)
    }
    
    // MARK: - FormatConversion Tests
    
    func testFormatConversionStereoToMono() {
        // Stereo: L R L R L R
        var input: [Float] = [1.0, 0.0, 1.0, 0.0, 1.0, 0.0]
        var output = [Float](repeating: 0, count: 3)
        
        let count = input.withUnsafeBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                FormatConversion.stereoToMono(
                    input: inPtr.baseAddress!,
                    inputCount: 6,
                    output: outPtr.baseAddress!,
                    outputCount: 3
                )
            }
        }
        
        XCTAssertEqual(count, 3)
        // Average of (1.0, 0.0) = 0.5
        XCTAssertEqual(output[0], 0.5)
        XCTAssertEqual(output[1], 0.5)
        XCTAssertEqual(output[2], 0.5)
    }
    
    func testFormatConversionInt16ToFloat32() {
        var input: [Int16] = [0, 16384, -16384, 32767]
        var output = [Float](repeating: 0, count: 4)
        
        input.withUnsafeBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                _ = FormatConversion.int16ToFloat32(
                    input: inPtr.baseAddress!,
                    inputCount: 4,
                    output: outPtr.baseAddress!
                )
            }
        }
        
        XCTAssertEqual(output[0], 0, accuracy: 0.001)
        XCTAssertEqual(output[1], 0.5, accuracy: 0.001)
        XCTAssertEqual(output[2], -0.5, accuracy: 0.001)
        XCTAssertEqual(output[3], 1.0, accuracy: 0.001)
    }
    
    // MARK: - AudioSynchronizer Tests
    
    func testAudioSynchronizerInitialState() {
        let synchronizer = AudioSynchronizer()
        
        XCTAssertEqual(synchronizer.state, .initializing)
        XCTAssertFalse(synchronizer.isStable)
    }
    
    func testAudioSynchronizerReset() {
        let synchronizer = AudioSynchronizer()
        
        // Push some data
        var samples = [Float](repeating: 0.5, count: 480)
        samples.withUnsafeBufferPointer { ptr in
            synchronizer.pushRender(samples: ptr.baseAddress!, count: 480, sampleTime: 0, hostTime: 0)
            synchronizer.pushCapture(samples: ptr.baseAddress!, count: 480, sampleTime: 0, hostTime: 0)
        }
        
        synchronizer.reset()
        
        XCTAssertEqual(synchronizer.state, .initializing)
    }
    
    func testAudioSynchronizerGetStats() {
        let synchronizer = AudioSynchronizer()
        let stats = synchronizer.getStats()
        
        XCTAssertEqual(stats.framesProcessed, 0)
        XCTAssertEqual(stats.discontinuities, 0)
    }
    
    // MARK: - AECProcessor Tests
    
    func testAECProcessorInitialState() {
        let processor = AECProcessor()
        
        XCTAssertEqual(processor.mode, .off)
        XCTAssertFalse(processor.isAdaptationFrozen)
    }
    
    func testAECProcessorConfigureHeadset() {
        let processor = AECProcessor()
        
        processor.configure(topology: .headset)
        
        XCTAssertEqual(processor.mode, .off)  // Headset = AEC off
    }
    
    func testAECProcessorConfigureSpeakerphone() {
        let processor = AECProcessor()
        
        processor.configure(topology: .speakerphone)
        
        XCTAssertEqual(processor.mode, .aggressive)  // Speakerphone = full AEC
    }
    
    func testAECProcessorFreeze() {
        let processor = AECProcessor()
        
        processor.freezeAdaptation()
        XCTAssertTrue(processor.isAdaptationFrozen)
        
        processor.unfreezeAdaptation()
        XCTAssertFalse(processor.isAdaptationFrozen)
    }
    
    func testAECProcessorGetStats() {
        let processor = AECProcessor()
        let stats = processor.getStats()
        
        XCTAssertEqual(stats.framesProcessed, 0)
        XCTAssertEqual(stats.framesSkipped, 0)
    }
}
