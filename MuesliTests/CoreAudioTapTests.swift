//
//  CoreAudioTapTests.swift
//  MuesliTests
//
//  Unit tests for the Core Audio Tap architecture.
//  Tests ring buffers, synchronizer, delay controller, and drift tracker.
//

import AudioToolbox
@testable import Muesli
import os.lock
import XCTest

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
    
    // MARK: - AudioFrameMetadataRing Tests

    func testMetadataRingPushPop() {
        let ring = AudioFrameMetadataRing(capacityFrames: 4)

        // Push 3 entries
        ring.push(hostTime: 100, startSampleIndex: 0)
        ring.push(hostTime: 200, startSampleIndex: 480)
        ring.push(hostTime: 300, startSampleIndex: 960)

        // Pop and verify order
        let first = ring.pop()
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.hostTime, 100)
        XCTAssertEqual(first?.startSampleIndex, 0)

        let second = ring.pop()
        XCTAssertNotNil(second)
        XCTAssertEqual(second?.hostTime, 200)
        XCTAssertEqual(second?.startSampleIndex, 480)

        let third = ring.pop()
        XCTAssertNotNil(third)
        XCTAssertEqual(third?.hostTime, 300)
        XCTAssertEqual(third?.startSampleIndex, 960)

        // Empty — should return nil
        let empty = ring.pop()
        XCTAssertNil(empty)
    }

    func testMetadataRingOverflow() {
        let ring = AudioFrameMetadataRing(capacityFrames: 2)

        // Push 3 entries into ring of capacity 2 — first should be dropped
        ring.push(hostTime: 100, startSampleIndex: 0)
        ring.push(hostTime: 200, startSampleIndex: 480)
        ring.push(hostTime: 300, startSampleIndex: 960)

        // First pop should be the second entry (first was dropped)
        let first = ring.pop()
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.hostTime, 200)

        let second = ring.pop()
        XCTAssertNotNil(second)
        XCTAssertEqual(second?.hostTime, 300)

        XCTAssertNil(ring.pop())
    }

    func testMetadataRingReset() {
        let ring = AudioFrameMetadataRing(capacityFrames: 4)

        ring.push(hostTime: 100, startSampleIndex: 0)
        ring.push(hostTime: 200, startSampleIndex: 480)

        ring.reset()

        // After reset, pop should return nil
        XCTAssertNil(ring.pop())

        // Can push again after reset
        ring.push(hostTime: 500, startSampleIndex: 0)
        let entry = ring.pop()
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.hostTime, 500)
    }

    // MARK: - TapCaptureRing Pop Tests

    func testTapCaptureRingPopConsumes() {
        let ring = TapCaptureRing(capacitySamples: 2000)

        // Push 960 samples with known pattern
        var samples = [Float](repeating: 0, count: 960)
        for i in 0..<960 { samples[i] = Float(i) }

        samples.withUnsafeBufferPointer { ptr in
            ring.push(samples: ptr.baseAddress!, count: 960, sampleTime: 0, hostTime: 0)
        }

        XCTAssertEqual(ring.available, 960)

        // Pop 480 samples (one AEC frame)
        var dest = [Float](repeating: 0, count: 480)
        let ok = dest.withUnsafeMutableBufferPointer { ptr in
            ring.pop(into: ptr.baseAddress!, count: 480)
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(ring.available, 480)
        XCTAssertEqual(dest[0], 0)
        XCTAssertEqual(dest[479], 479)

        // Pop remaining
        let ok2 = dest.withUnsafeMutableBufferPointer { ptr in
            ring.pop(into: ptr.baseAddress!, count: 480)
        }
        XCTAssertTrue(ok2)
        XCTAssertEqual(dest[0], 480)
        XCTAssertEqual(ring.available, 0)
    }

    // MARK: - AudioWorker Lead Cap Tests

    func testAudioWorkerRenderLeadBounded() {
        // Create rings and worker with only render frames (no capture).
        let synchronizer = AudioSynchronizer()
        let aec = AECProcessor()
        aec.configure(topology: .speakerphone)

        let renderRing = TapCaptureRing(capacityMs: 600)

        // Pre-fill render ring with 50 frames (500ms) of silence
        let silence = [Float](repeating: 0, count: 480)
        for i in 0..<50 {
            silence.withUnsafeBufferPointer { ptr in
                renderRing.push(
                    samples: ptr.baseAddress!,
                    count: 480,
                    sampleTime: Float64(i * 480),
                    hostTime: 0
                )
            }
        }

        nonisolated(unsafe) let renderRingRef = renderRing
        let renderFrameCounter = OSAllocatedUnfairLock(initialState: Int64(0))

        let worker = AudioWorker(
            synchronizer: synchronizer,
            aecProcessor: aec,
            popRenderAECFrame: { dest in
                guard renderRingRef.pop(into: dest, count: 480) else { return nil }
                let idx = renderFrameCounter.withLock { count -> Int64 in
                    let current = count
                    count += 1
                    return current
                }
                return (hostTime: 0, startSampleIndex: idx * 480)
            },
            popCaptureAECFrame: { _ in
                // No capture frames available
                return nil
            }
        )

        // Collect stats — start worker briefly
        worker.start(
            micCallback: { _ in },
            renderCallback: { _ in }
        )

        // Let it run for a short period (enough to process available frames)
        Thread.sleep(forTimeInterval: 0.1)
        worker.stop()

        let stats = worker.getStats()

        // With 50 render frames available and 0 capture frames,
        // the lead should be bounded by maxRenderLeadFrames (30).
        XCTAssertLessThanOrEqual(stats.renderLeadFrames, Int64(AudioWorker.maxRenderLeadFrames) + 1,
            "Render lead should be bounded by maxRenderLeadFrames")
    }
}

// MARK: - TapAudioCaptureService Permission Tests

final class TapAudioCaptureServicePermissionTests: XCTestCase {
    func testStartCaptureAttempsTapEvenWhenCachedPermissionIsFalse() async throws {
        // Given: A service with cached permission check returning false
        let service = TapAudioCaptureService(checkPermission: { false })
        await service.setBufferHandler { _, _ in }

        // When: startCapture is called, it should NOT throw permissionDenied.
        // The service now logs a warning and attempts the tap anyway
        // (the tap itself is the authoritative check).
        // It may throw other errors like tapCreationFailed in test env — that's fine.
        do {
            try await service.startCapture()
        } catch let error as AudioCaptureError {
            XCTAssertNotEqual(
                error.localizedDescription,
                AudioCaptureError.permissionDenied.localizedDescription,
                "Should not throw permissionDenied — service should attempt tap regardless of cached permission"
            )
        } catch {
            // Other errors are fine — tap creation may fail in test environment
        }

        // Cleanup
        try? await service.stopCapture()
    }

    func testStartCaptureDoesNotThrowPermissionDeniedWhenGranted() async throws {
        // Given: A service with permission check that returns true
        let service = TapAudioCaptureService(checkPermission: { true })
        await service.setBufferHandler { _, _ in }

        // When: startCapture is called, it should pass the permission check
        // (it may throw a different error like tapCreationFailed since we're in test env,
        // but it should NOT throw permissionDenied)
        do {
            try await service.startCapture()
        } catch let error as AudioCaptureError {
            // Any error other than permissionDenied is acceptable
            XCTAssertNotEqual(
                error.localizedDescription,
                AudioCaptureError.permissionDenied.localizedDescription,
                "Should not throw permissionDenied when permission is granted"
            )
        } catch {
            // Other errors are fine — tap creation may fail in test environment
        }

        // Cleanup
        try? await service.stopCapture()
    }
}

// MARK: - AEC Pipeline Regression Tests

extension CoreAudioTapTests {
    // MARK: - Ring Discontinuity Detection Tests

    func testTapCaptureRingNoDiscontinuityOnValidGaps() {
        let ring = TapCaptureRing(capacitySamples: 48000)
        let samples = [Float](repeating: 0.1, count: 480)

        // Push 20 callbacks with exact 480-sample gaps
        for i in 0..<20 {
            samples.withUnsafeBufferPointer { ptr in
                ring.push(samples: ptr.baseAddress!, count: 480, sampleTime: Float64(i * 480), hostTime: 0)
            }
        }

        XCTAssertFalse(ring.hasDiscontinuity, "Valid 480-sample gaps should not trigger discontinuity")
    }

    func testTapCaptureRingNoDiscontinuityOnSlightlyNegativeDelta() {
        let ring = TapCaptureRing(capacitySamples: 48000)
        let samples = [Float](repeating: 0.1, count: 480)

        // Push warmup callbacks
        for i in 0..<15 {
            samples.withUnsafeBufferPointer { ptr in
                ring.push(samples: ptr.baseAddress!, count: 480, sampleTime: Float64(i * 480), hostTime: 0)
            }
        }

        // Push with -2 sample delta (within -240 tolerance)
        let lastExpected = Float64(15 * 480)
        samples.withUnsafeBufferPointer { ptr in
            ring.push(samples: ptr.baseAddress!, count: 480, sampleTime: lastExpected - 2, hostTime: 0)
        }

        XCTAssertFalse(ring.hasDiscontinuity, "-2 sample delta should not trigger discontinuity (tolerance is -240)")
    }

    func testTapCaptureRingDiscontinuityOnLargeGap() {
        let ring = TapCaptureRing(capacitySamples: 96000)
        let samples = [Float](repeating: 0.1, count: 480)

        // Push warmup callbacks
        for i in 0..<15 {
            samples.withUnsafeBufferPointer { ptr in
                ring.push(samples: ptr.baseAddress!, count: 480, sampleTime: Float64(i * 480), hostTime: 0)
            }
        }
        XCTAssertFalse(ring.hasDiscontinuity, "No discontinuity during normal operation")

        // Push with 48000-sample gap (1 second) — should fire immediately
        let nextTime = Float64(15 * 480) + 48000
        samples.withUnsafeBufferPointer { ptr in
            ring.push(samples: ptr.baseAddress!, count: 480, sampleTime: nextTime, hostTime: 0)
        }

        XCTAssertTrue(ring.hasDiscontinuity, "48000-sample gap should trigger discontinuity")
    }

    func testTapCaptureRingWarmupSuppression() {
        let ring = TapCaptureRing(capacitySamples: 48000)
        let samples = [Float](repeating: 0.1, count: 480)

        // Push with irregular gap during first 10 callbacks (warmup)
        samples.withUnsafeBufferPointer { ptr in
            ring.push(samples: ptr.baseAddress!, count: 480, sampleTime: 0, hostTime: 0)
        }

        // Large gap during warmup — should be suppressed
        samples.withUnsafeBufferPointer { ptr in
            ring.push(samples: ptr.baseAddress!, count: 480, sampleTime: 48000, hostTime: 0)
        }

        XCTAssertFalse(ring.hasDiscontinuity, "Irregular gaps during warmup should be suppressed")
    }

    func testTapCaptureRingDebounceFirstEventFires() {
        let ring = TapCaptureRing(capacitySamples: 96000)
        let samples = [Float](repeating: 0.1, count: 480)

        // Push warmup callbacks (11 to pass warmup threshold of 10)
        for i in 0..<11 {
            samples.withUnsafeBufferPointer { ptr in
                ring.push(samples: ptr.baseAddress!, count: 480, sampleTime: Float64(i * 480), hostTime: 0)
            }
        }
        XCTAssertFalse(ring.hasDiscontinuity, "No discontinuity after normal warmup")

        // First genuine discontinuity fires immediately (debounceRemaining starts at 0)
        let nextTime = Float64(11 * 480) + 48000
        samples.withUnsafeBufferPointer { ptr in
            ring.push(samples: ptr.baseAddress!, count: 480, sampleTime: nextTime, hostTime: 0)
        }

        XCTAssertTrue(ring.hasDiscontinuity, "First discontinuity after warmup should fire immediately")
    }

    func testMicCaptureRingNoDiscontinuityOnSlightlyNegativeDelta() {
        let ring = MicCaptureRing(capacitySamples: 48000)
        let samples = [Float](repeating: 0.1, count: 480)

        // Push warmup callbacks
        for i in 0..<15 {
            samples.withUnsafeBufferPointer { ptr in
                ring.push(samples: ptr.baseAddress!, count: 480, sampleTime: Float64(i * 480), hostTime: 0)
            }
        }

        // Push with -2 sample delta (within tolerance)
        let lastExpected = Float64(15 * 480)
        samples.withUnsafeBufferPointer { ptr in
            ring.push(samples: ptr.baseAddress!, count: 480, sampleTime: lastExpected - 2, hostTime: 0)
        }

        XCTAssertFalse(ring.hasDiscontinuity, "-2 sample delta should not trigger discontinuity in mic ring")
    }

    // MARK: - AudioSynchronizer Regression Tests

    func testSynchronizerResetForNewSessionNoCooldown() {
        let synchronizer = AudioSynchronizer()

        // Simulate some state
        var samples = [Float](repeating: 0.5, count: 480)
        samples.withUnsafeBufferPointer { ptr in
            synchronizer.pushRender(samples: ptr.baseAddress!, count: 480, sampleTime: 0, hostTime: 0)
            synchronizer.pushCapture(samples: ptr.baseAddress!, count: 480, sampleTime: 0, hostTime: 0)
        }

        synchronizer.resetForNewSession()

        XCTAssertEqual(synchronizer.state, .initializing)
        let stats = synchronizer.getStats()
        XCTAssertEqual(stats.discontinuities, 0, "Fresh session should have 0 discontinuities")
        XCTAssertEqual(stats.framesProcessed, 0, "Fresh session should have 0 frames processed")
    }

    func testSynchronizerStableGateWithModerateRenderLead() {
        // Use fast timing config so we don't need to wait real seconds
        let config = AudioSynchronizer.TimingConfig(
            minNoDiscontinuitySeconds: 0.0,  // No waiting
            discontinuityDebounceSeconds: 0.0
        )
        let synchronizer = AudioSynchronizer(timingConfig: config)

        let silence = [Float](repeating: 0, count: 480)

        // Push render lead of ~130ms (6240 samples = 13 frames)
        // This is between old threshold (150ms=7200) and new threshold (100ms=4800)
        for i in 0..<13 {
            silence.withUnsafeBufferPointer { ptr in
                synchronizer.pushRender(samples: ptr.baseAddress!, count: 480, sampleTime: Float64(i * 480), hostTime: 0)
            }
        }

        // Push one capture frame
        silence.withUnsafeBufferPointer { ptr in
            synchronizer.pushCapture(samples: ptr.baseAddress!, count: 480, sampleTime: 0, hostTime: 0)
        }

        // Try to get aligned frame — should transition through priming to stable
        let frame = synchronizer.getAlignedFrame()

        XCTAssertNotNil(frame, "Should produce aligned frame with 130ms render lead (>100ms threshold)")
        XCTAssertEqual(synchronizer.state, .stable, "Should transition to stable with 130ms lead")
    }

    func testSynchronizerStableAfterDiscontinuityFlood() {
        // Fast timing: 100ms debounce, 200ms recovery
        let config = AudioSynchronizer.TimingConfig(
            minNoDiscontinuitySeconds: 0.2,
            discontinuityDebounceSeconds: 0.1
        )
        let synchronizer = AudioSynchronizer(timingConfig: config)

        let silence = [Float](repeating: 0, count: 480)

        // Helper to push a normal render frame
        func pushRender(_ i: Int) {
            silence.withUnsafeBufferPointer { ptr in
                synchronizer.pushRender(samples: ptr.baseAddress!, count: 480,
                                        sampleTime: Float64(i * 480), hostTime: 0)
            }
        }

        // Warmup: push 15 normal render frames to clear ring debounce/warmup
        for i in 0..<15 { pushRender(i) }
        silence.withUnsafeBufferPointer { ptr in
            synchronizer.pushCapture(samples: ptr.baseAddress!, count: 480, sampleTime: 0, hostTime: 0)
        }

        // Drive a flood of real discontinuities through pushRender (1-second gaps).
        // The cooldown-debounce means only the first of each pair within 100ms refreshes
        // lastDiscontinuityTime; subsequent rapid ones are suppressed.
        // We send 10 discontinuous frames in rapid succession.
        var baseSampleTime = Float64(15 * 480)
        for _ in 0..<10 {
            baseSampleTime += 48000  // 1-second jump each time
            silence.withUnsafeBufferPointer { ptr in
                synchronizer.pushRender(samples: ptr.baseAddress!, count: 480,
                                        sampleTime: baseSampleTime, hostTime: 0)
            }
        }

        // Synchronizer should be unstable now
        // (state may be .unstable or still .initializing depending on prior transitions)

        // Wait just past the recovery window (minNoDiscontinuitySeconds / 2 = 0.1s, so 0.15s is enough)
        Thread.sleep(forTimeInterval: 0.25)

        // Re-push enough stable render lead + capture to satisfy canTransitionToStable
        let recoveryBase = Int(baseSampleTime / 480) + 1
        for i in 0..<20 {
            silence.withUnsafeBufferPointer { ptr in
                synchronizer.pushRender(samples: ptr.baseAddress!, count: 480,
                                        sampleTime: Float64((recoveryBase + i) * 480), hostTime: 0)
            }
        }
        silence.withUnsafeBufferPointer { ptr in
            synchronizer.pushCapture(samples: ptr.baseAddress!, count: 480,
                                     sampleTime: Float64(recoveryBase * 480), hostTime: 0)
        }

        let frame = synchronizer.getAlignedFrame()
        XCTAssertNotNil(frame, "Should recover to stable after discontinuity flood + wait")

        // Also verify that total discontinuity count is bounded:
        // 10 large-gap pushes, but the ring's debounce (5-callback window) means not all
        // of them fire as ring-level discontinuities. The synchronizer discontinuity count
        // should be well under 10.
        let stats = synchronizer.getStats()
        XCTAssertLessThan(stats.discontinuities, 10,
            "Debounce should limit synchronizer discontinuity count during a rapid flood")
    }
}
