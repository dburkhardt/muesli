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

    func testCoarseDelayControllerBluetoothProfileLowersDeadband() {
        let defaultProfileController = CoarseDelayController()
        defaultProfileController.update(observedDelaySamples: 500)
        XCTAssertEqual(
            defaultProfileController.currentDelaySamples,
            0,
            "Default profile should ignore 500-sample updates inside 15ms deadband"
        )

        let btProfileController = CoarseDelayController()
        btProfileController.setBluetoothExternalMicProfile(true)
        btProfileController.update(observedDelaySamples: 500)
        XCTAssertGreaterThan(
            btProfileController.currentDelaySamples,
            0,
            "BT profile should react to 500-sample updates due to tighter deadband"
        )
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
            micCallback: { _ in }
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

    func testAudioWorkerFeedsSynchronizerDelayHintToAEC() async throws {
        let config = AudioSynchronizer.TimingConfig(
            minNoDiscontinuitySeconds: 0.0,
            discontinuityDebounceSeconds: 0.0
        )
        let synchronizer = AudioSynchronizer(timingConfig: config)
        let aec = AECProcessor()
        aec.configure(topology: .speakerphone, synchronizer: synchronizer)

        // Prime synchronizer into stable state with non-zero render lead.
        let silence = [Float](repeating: 0, count: 480)
        for i in 0..<15 {
            silence.withUnsafeBufferPointer { ptr in
                synchronizer.pushRender(
                    samples: ptr.baseAddress!,
                    count: 480,
                    sampleTime: Float64(i * 480),
                    hostTime: 0
                )
            }
        }
        silence.withUnsafeBufferPointer { ptr in
            synchronizer.pushCapture(
                samples: ptr.baseAddress!,
                count: 480,
                sampleTime: 0,
                hostTime: 0
            )
        }
        _ = synchronizer.getAlignedFrame()
        XCTAssertGreaterThan(synchronizer.coarseDelayMs, 0, "Precondition: synchronizer should expose a non-zero delay hint")

        let renderRing = TapCaptureRing(capacityMs: 200)
        let captureRing = TapCaptureRing(capacityMs: 200)
        for i in 0..<6 {
            silence.withUnsafeBufferPointer { ptr in
                renderRing.push(
                    samples: ptr.baseAddress!,
                    count: 480,
                    sampleTime: Float64(i * 480),
                    hostTime: 0
                )
                captureRing.push(
                    samples: ptr.baseAddress!,
                    count: 480,
                    sampleTime: Float64(i * 480),
                    hostTime: 0
                )
            }
        }

        nonisolated(unsafe) let renderRingRef = renderRing
        nonisolated(unsafe) let captureRingRef = captureRing
        let renderCounter = OSAllocatedUnfairLock(initialState: Int64(0))
        let captureCounter = OSAllocatedUnfairLock(initialState: Int64(0))

        let worker = AudioWorker(
            synchronizer: synchronizer,
            aecProcessor: aec,
            popRenderAECFrame: { dest in
                guard renderRingRef.pop(into: dest, count: 480) else { return nil }
                let idx = renderCounter.withLock { count -> Int64 in
                    let current = count
                    count += 1
                    return current
                }
                return (hostTime: 0, startSampleIndex: idx * 480)
            },
            popCaptureAECFrame: { dest in
                guard captureRingRef.pop(into: dest, count: 480) else { return nil }
                let idx = captureCounter.withLock { count -> Int64 in
                    let current = count
                    count += 1
                    return current
                }
                return (hostTime: 0, startSampleIndex: idx * 480)
            }
        )

        let processedExpectation = expectation(description: "Capture frame processed")
        processedExpectation.assertForOverFulfill = false
        worker.start { _ in
            processedExpectation.fulfill()
        }
        defer { worker.stop() }

        await fulfillment(of: [processedExpectation], timeout: 1.0)

        let lastDelayMs = aec.getStats().lastStreamDelayMs
        if lastDelayMs == -1 {
            throw XCTSkip("AEC bridge unavailable in this environment")
        }
        XCTAssertGreaterThan(lastDelayMs, 0, "AudioWorker should feed non-zero synchronizer delay hint to AEC")
    }

    func testAudioWorkerUsesCoarseDelayWhenAvailable() {
        let selection = AudioWorker.selectStreamDelayHint(
            coarseDelayMs: 175,
            seededDelayMs: 80
        )
        XCTAssertEqual(selection.delayMs, 175, "Coarse delay should take precedence when available")
        XCTAssertEqual(selection.source, .coarse)
    }

    func testAudioWorkerFallsBackToSeededDelayWhenCoarseZero() {
        let selection = AudioWorker.selectStreamDelayHint(
            coarseDelayMs: 0,
            seededDelayMs: 80
        )
        XCTAssertEqual(selection.delayMs, 80, "Seeded delay should be used when coarse delay is not available")
        XCTAssertEqual(selection.source, .seeded)
    }

    func testAudioWorkerDelayHintSelectsNoneWhenUnavailable() {
        let selection = AudioWorker.selectStreamDelayHint(
            coarseDelayMs: 0,
            seededDelayMs: -1
        )
        XCTAssertEqual(selection.delayMs, 0, "When no delay estimates are available, hint should be zero")
        XCTAssertEqual(selection.source, .none)
    }

    func testAudioWorkerDelayHintControlHoldsHintDuringUnstableWindows() {
        let decision = AudioWorker.applyDelayHintControl(
            requestedDelayMs: 220,
            source: .coarse,
            lastAppliedDelayMs: 180,
            lastAppliedSource: .seeded,
            isStable: false,
            enabled: true
        )
        XCTAssertEqual(decision.delayMs, 180, "Unstable windows should hold last applied delay hint")
        XCTAssertEqual(decision.source, .seeded, "Unstable hold should preserve last applied source")
        XCTAssertTrue(decision.heldInUnstableWindow, "Decision should mark unstable-window hold")
        XCTAssertFalse(decision.clamped)
    }

    func testAudioWorkerDelayHintControlSlewLimitsLargeStableJump() {
        let decision = AudioWorker.applyDelayHintControl(
            requestedDelayMs: 220,
            source: .coarse,
            lastAppliedDelayMs: 180,
            lastAppliedSource: .seeded,
            isStable: true,
            enabled: true,
            slewLimitMsPerFrame: 8
        )
        XCTAssertEqual(decision.delayMs, 188, "Stable windows should apply slew-limited delay transitions")
        XCTAssertEqual(decision.source, .coarse, "Stable path should keep requested source")
        XCTAssertTrue(decision.clamped)
        XCTAssertFalse(decision.heldInUnstableWindow)
    }

    func testAudioWorkerBtProfileDelayBiasAppliesToDelayHint() {
        let adjusted = AudioWorker.applyBtProfileDelayBias(
            selectedHint: (delayMs: 200, source: .coarse),
            btExternalMicProfileActive: true,
            biasMs: 80
        )
        XCTAssertEqual(adjusted.delayMs, 280)
        XCTAssertEqual(adjusted.source, .coarse)
    }

    func testAudioWorkerBtProfileDelayBiasDoesNotChangeNoneSource() {
        let adjusted = AudioWorker.applyBtProfileDelayBias(
            selectedHint: (delayMs: 0, source: .none),
            btExternalMicProfileActive: true,
            biasMs: 80
        )
        XCTAssertEqual(adjusted.delayMs, 0)
        XCTAssertEqual(adjusted.source, .none)
    }

    func testAudioWorkerBtRecoveryTriggersAfterSustainedLowAttenuation() {
        let shouldRecover = AudioWorker.shouldTriggerBtRecovery(
            btExternalMicProfileActive: true,
            startupGateState: .fullAdaptation,
            lowAttenuationSeconds: 20,
            attemptCount: 0
        )
        XCTAssertTrue(shouldRecover, "BT recovery should trigger after sustained low attenuation in full adaptation")
    }

    func testAudioWorkerBtRecoveryRequiresFullAdaptationState() {
        let shouldRecover = AudioWorker.shouldTriggerBtRecovery(
            btExternalMicProfileActive: true,
            startupGateState: .waitingDelayReady,
            lowAttenuationSeconds: 30,
            attemptCount: 0
        )
        XCTAssertFalse(shouldRecover, "Recovery should stay off until startup gate reaches full adaptation")
    }

    func testAudioWorkerBtRecoveryHonorsAttemptLimit() {
        let shouldRecover = AudioWorker.shouldTriggerBtRecovery(
            btExternalMicProfileActive: true,
            startupGateState: .fullAdaptation,
            lowAttenuationSeconds: 30,
            attemptCount: 1
        )
        XCTAssertFalse(shouldRecover, "Recovery should not retrigger once max per-route attempts are consumed")
    }

    func testAudioWorkerStartupGateTransitionsToDelayReadyAfterRenderWarmup() {
        let transition = AudioWorker.transitionStartupGateState(
            currentState: .waitingRenderReady,
            renderReadyStreak: 5,
            delayReadyStreak: 0,
            elapsedMs: 500,
            renderReadyFrames: 5,
            delayReadyFrames: 10,
            timeoutMs: 15_000
        )
        XCTAssertEqual(transition.nextState, .waitingDelayReady)
        XCTAssertNil(transition.releaseReason)
    }

    func testAudioWorkerStartupGateTransitionsToFullAfterDelayReady() {
        let transition = AudioWorker.transitionStartupGateState(
            currentState: .waitingDelayReady,
            renderReadyStreak: 5,
            delayReadyStreak: 10,
            elapsedMs: 1_000,
            renderReadyFrames: 5,
            delayReadyFrames: 10,
            timeoutMs: 15_000
        )
        XCTAssertEqual(transition.nextState, .fullAdaptation)
        XCTAssertEqual(transition.releaseReason, "render_and_delay_ready")
    }

    func testAudioWorkerStartupGateTransitionsToGuardedOnTimeout() {
        let transition = AudioWorker.transitionStartupGateState(
            currentState: .waitingRenderReady,
            renderReadyStreak: 0,
            delayReadyStreak: 0,
            elapsedMs: 15_000,
            renderReadyFrames: 5,
            delayReadyFrames: 10,
            timeoutMs: 15_000
        )
        XCTAssertEqual(transition.nextState, .guardedTimeout)
        XCTAssertEqual(transition.releaseReason, "timeout_guarded")
    }

    func testRouteCoalesceDelayHonorsMaxWindowCap() {
        let firstEvent = Date(timeIntervalSince1970: 1000)
        let delayNearStart = TapAudioCaptureService.nextRouteCoalesceDelayMs(
            firstEventAt: firstEvent,
            now: Date(timeIntervalSince1970: 1000.2)
        )
        XCTAssertEqual(delayNearStart, 1500, "Early clustered events should use full debounce window")

        let delayNearCap = TapAudioCaptureService.nextRouteCoalesceDelayMs(
            firstEventAt: firstEvent,
            now: Date(timeIntervalSince1970: 1003.8)
        )
        XCTAssertTrue((199...201).contains(delayNearCap),
                      "Delay should shrink as max coalescing cap is approached")

        let delayPastCap = TapAudioCaptureService.nextRouteCoalesceDelayMs(
            firstEventAt: firstEvent,
            now: Date(timeIntervalSince1970: 1004.2)
        )
        XCTAssertEqual(delayPastCap, 0, "Delay should clamp to zero once max coalescing window is exceeded")
    }

    func testTapMicBufferSizingUsesBtProfileSpecificValues() {
        let defaultTapFrames = TapAudioCaptureService.microphoneTapBufferFramesForProfile(
            btExternalMicProfileActive: false
        )
        let btTapFrames = TapAudioCaptureService.microphoneTapBufferFramesForProfile(
            btExternalMicProfileActive: true
        )
        XCTAssertEqual(defaultTapFrames, 4096)
        XCTAssertEqual(btTapFrames, 2048)
    }

    func testTapMicResamplerCapacityUsesTighterBtMargin() {
        let defaultCapacity = TapAudioCaptureService.microphoneResamplerOutputFrameCapacity(
            inputFrameCount: 4410,
            inputSampleRate: 44_100,
            btExternalMicProfileActive: false
        )
        let btCapacity = TapAudioCaptureService.microphoneResamplerOutputFrameCapacity(
            inputFrameCount: 4410,
            inputSampleRate: 44_100,
            btExternalMicProfileActive: true
        )
        XCTAssertEqual(defaultCapacity, 5824)
        XCTAssertEqual(btCapacity, 5056)
        XCTAssertLessThan(
            btCapacity,
            defaultCapacity,
            "BT profile should reduce converter output capacity margin to avoid bursty frame output"
        )
    }

    func testTapMicResamplerChannelMapPinsFirstChannelForMultiChannelInput() {
        let channelMap = TapAudioCaptureService.microphoneResamplerChannelMapForTapChannels(2)
        XCTAssertEqual(channelMap, [NSNumber(value: 0)])
    }

    func testTapMicResamplerChannelMapUsesChannelZeroForMonoInput() {
        let channelMap = TapAudioCaptureService.microphoneResamplerChannelMapForTapChannels(1)
        XCTAssertEqual(channelMap, [NSNumber(value: 0)])
    }

    func testEvaluateMicSignalContractAcceptsConverterAlignedContract() {
        let result = TapAudioCaptureService.evaluateMicSignalContract(
            sourceSampleRate: 16_000,
            deliveryChannels: 1,
            converterSourceChannels: 1,
            converterOutputSampleRate: 48_000,
            converterEnabled: true
        )
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.reason, "converter_contract_ok")
    }

    func testEvaluateMicSignalContractRejectsConverterChannelMismatch() {
        let result = TapAudioCaptureService.evaluateMicSignalContract(
            sourceSampleRate: 44_100,
            deliveryChannels: 1,
            converterSourceChannels: 2,
            converterOutputSampleRate: 48_000,
            converterEnabled: true
        )
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.reason, "converter_source_channels_mismatch")
    }

    func testEvaluateMicSignalContractRejectsNativeNon48kWithoutConverter() {
        let result = TapAudioCaptureService.evaluateMicSignalContract(
            sourceSampleRate: 44_100,
            deliveryChannels: 1,
            converterSourceChannels: 1,
            converterOutputSampleRate: 44_100,
            converterEnabled: false
        )
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.reason, "native_source_rate_not_48k_without_converter")
    }

    func testConverterRecoveryEscalationDecisionEscalatesToFallbackAtThreshold() {
        let decision = TapAudioCaptureService.converterRecoveryEscalationDecision(
            recoveriesInWindow: 3,
            fallbackAlreadyForced: false
        )
        XCTAssertTrue(decision.escalateToFallback)
        XCTAssertFalse(decision.disableAecPath)
    }

    func testConverterRecoveryEscalationDecisionDisablesAecWhenFallbackAlreadyForced() {
        let decision = TapAudioCaptureService.converterRecoveryEscalationDecision(
            recoveriesInWindow: 3,
            fallbackAlreadyForced: true
        )
        XCTAssertFalse(decision.escalateToFallback)
        XCTAssertTrue(decision.disableAecPath)
    }

    func testConverterFailureZeroFillFrameCountUses48kDomainWhenResamplerActive() {
        let frameCount = TapAudioCaptureService.converterFailureZeroFillFrameCount(
            inputFrameCount: 4096,
            sourceSampleRate: 16_000,
            resamplerActive: true
        )
        XCTAssertEqual(frameCount, 12_288)
    }

    func testConverterFailureZeroFillFrameCountUsesInputFramesWithoutResampler() {
        let frameCount = TapAudioCaptureService.converterFailureZeroFillFrameCount(
            inputFrameCount: 480,
            sourceSampleRate: 48_000,
            resamplerActive: false
        )
        XCTAssertEqual(frameCount, 480)
    }

    func testMicrophoneRouteRebindDecisionTriggersDuringStartupWithoutCaptureAudio() {
        let decision = TapAudioCaptureService.microphoneRouteRebindDecision(
            previousAppliedInputUID: "08-FF-44-49-A4-D3:input",
            refreshedInputUID: "AppleUSBAudioEngine:Unknown Manufacturer:HD Pro Webcam C920:FAEA515F:3",
            selectedMicrophoneUID: "AppleUSBAudioEngine:Unknown Manufacturer:HD Pro Webcam C920:FAEA515F:3",
            hasActiveMicrophoneEngine: true,
            hasSeenCaptureAudio: false
        )
        XCTAssertTrue(decision.shouldRebind)
        XCTAssertEqual(decision.reason, "startup_no_capture_audio")
    }

    func testMicrophoneRouteRebindDecisionTriggersWhenInputUIDChanges() {
        let decision = TapAudioCaptureService.microphoneRouteRebindDecision(
            previousAppliedInputUID: "08-FF-44-49-A4-D3:input",
            refreshedInputUID: "AppleUSBAudioEngine:Unknown Manufacturer:HD Pro Webcam C920:FAEA515F:3",
            selectedMicrophoneUID: nil,
            hasActiveMicrophoneEngine: true,
            hasSeenCaptureAudio: true
        )
        XCTAssertTrue(decision.shouldRebind)
        XCTAssertEqual(decision.reason, "input_uid_changed")
    }

    func testMicrophoneRouteRebindDecisionTriggersOnSelectedUIDMismatch() {
        let decision = TapAudioCaptureService.microphoneRouteRebindDecision(
            previousAppliedInputUID: "08-FF-44-49-A4-D3:input",
            refreshedInputUID: "08-FF-44-49-A4-D3:input",
            selectedMicrophoneUID: "AppleUSBAudioEngine:Unknown Manufacturer:HD Pro Webcam C920:FAEA515F:3",
            hasActiveMicrophoneEngine: true,
            hasSeenCaptureAudio: true
        )
        XCTAssertTrue(decision.shouldRebind)
        XCTAssertEqual(decision.reason, "selected_uid_mismatch")
    }

    func testMicrophoneRouteRebindDecisionSkipsWhenRouteStable() {
        let decision = TapAudioCaptureService.microphoneRouteRebindDecision(
            previousAppliedInputUID: "AppleUSBAudioEngine:Unknown Manufacturer:HD Pro Webcam C920:FAEA515F:3",
            refreshedInputUID: "AppleUSBAudioEngine:Unknown Manufacturer:HD Pro Webcam C920:FAEA515F:3",
            selectedMicrophoneUID: "AppleUSBAudioEngine:Unknown Manufacturer:HD Pro Webcam C920:FAEA515F:3",
            hasActiveMicrophoneEngine: true,
            hasSeenCaptureAudio: true
        )
        XCTAssertFalse(decision.shouldRebind)
        XCTAssertEqual(decision.reason, "no_rebind_needed")
    }

    func testMicrophoneRouteRebindDecisionSkipsWithoutActiveEngine() {
        let decision = TapAudioCaptureService.microphoneRouteRebindDecision(
            previousAppliedInputUID: "08-FF-44-49-A4-D3:input",
            refreshedInputUID: "AppleUSBAudioEngine:Unknown Manufacturer:HD Pro Webcam C920:FAEA515F:3",
            selectedMicrophoneUID: "AppleUSBAudioEngine:Unknown Manufacturer:HD Pro Webcam C920:FAEA515F:3",
            hasActiveMicrophoneEngine: false,
            hasSeenCaptureAudio: false
        )
        XCTAssertFalse(decision.shouldRebind)
        XCTAssertEqual(decision.reason, "no_active_engine")
    }

    func testMicSilentRecoveryTriggersForSustainedDigitalSilence() {
        let shouldRecover = TapAudioCaptureService.shouldTriggerMicSilentRecovery(
            btExternalMicProfileActive: true,
            sourceRms: 0,
            pipelineRms: 0,
            consecutiveSilentCallbacks: 40,
            attemptsInCurrentRoute: 0,
            isRecoveryInFlight: false
        )
        XCTAssertTrue(shouldRecover)
    }

    func testMicSilentRecoveryDoesNotTriggerForNonZeroSignal() {
        let shouldRecover = TapAudioCaptureService.shouldTriggerMicSilentRecovery(
            btExternalMicProfileActive: true,
            sourceRms: 0.01,
            pipelineRms: 0.01,
            consecutiveSilentCallbacks: 100,
            attemptsInCurrentRoute: 0,
            isRecoveryInFlight: false
        )
        XCTAssertFalse(shouldRecover)
    }

    func testMicSilentRecoveryHonorsAttemptLimit() {
        let shouldRecover = TapAudioCaptureService.shouldTriggerMicSilentRecovery(
            btExternalMicProfileActive: true,
            sourceRms: 0,
            pipelineRms: 0,
            consecutiveSilentCallbacks: 100,
            attemptsInCurrentRoute: 2,
            isRecoveryInFlight: false
        )
        XCTAssertFalse(shouldRecover)
    }

    func testMicNoCallbackRecoveryTriggersWhenBtProfileHasNoCallbacks() {
        let shouldRecover = TapAudioCaptureService.shouldTriggerMicNoCallbackRecovery(
            btExternalMicProfileActive: true,
            totalCallbacks: 0,
            attemptsInCurrentRoute: 0,
            isRecoveryInFlight: false
        )
        XCTAssertTrue(shouldRecover)
    }

    func testMicNoCallbackRecoveryRequiresBtProfile() {
        let shouldRecover = TapAudioCaptureService.shouldTriggerMicNoCallbackRecovery(
            btExternalMicProfileActive: false,
            totalCallbacks: 0,
            attemptsInCurrentRoute: 0,
            isRecoveryInFlight: false
        )
        XCTAssertFalse(shouldRecover)
    }

    func testPhase15RenderRmsUsesLatestWhenRenderUpdated() {
        let renderRms = AudioWorker.phase15RenderRmsForFrame(
            latestRenderRmsLinear: 0.25,
            renderUpdatedThisIteration: true
        )
        XCTAssertEqual(renderRms, 0.25, accuracy: 0.000_1)
    }

    func testPhase15RenderRmsZeroFillsWhenRenderNotUpdated() {
        let renderRms = AudioWorker.phase15RenderRmsForFrame(
            latestRenderRmsLinear: 0.25,
            renderUpdatedThisIteration: false
        )
        XCTAssertEqual(renderRms, 0, accuracy: 0.000_1)
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
        let ring = MicCaptureRing(capacitySamples: 120000)
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

    // MARK: - MicCaptureRing Sample-Time Domain Mismatch Regression

    func testMicCaptureRingDomainMismatchCausesFalseDiscontinuity() {
        let ring = MicCaptureRing(capacitySamples: 120000)

        // Simulate a C920 webcam: AVAudioEngine delivers ~4096 frames at 44.1kHz,
        // but after resampling to 48kHz the count is ~4458.
        // The OLD bug: pass 44.1kHz sampleTime with 48kHz sampleCount.
        let sourceSampleRate = 44100
        let targetSampleRate = 48000
        let sourceFramesPerCallback = 4096
        let resampledFramesPerCallback = Int(Double(sourceFramesPerCallback) * Double(targetSampleRate) / Double(sourceSampleRate))
        let samples = [Float](repeating: 0.1, count: resampledFramesPerCallback)

        // Warmup phase (10 callbacks required by MicCaptureRing)
        for i in 0..<12 {
            let sourceSampleTime = Float64(i * sourceFramesPerCallback)
            samples.withUnsafeBufferPointer { ptr in
                ring.push(
                    samples: ptr.baseAddress!,
                    count: resampledFramesPerCallback,
                    sampleTime: sourceSampleTime,
                    hostTime: 0
                )
            }
            ring.clearDiscontinuity()
        }

        // After warmup, the next push with the domain mismatch should trigger a
        // discontinuity. The delta is sourceFramesPerCallback - resampledFramesPerCallback
        // = 4096 - 4458 = -362, which is below negativeTolerance (-240).
        let triggerSampleTime = Float64(12 * sourceFramesPerCallback)
        samples.withUnsafeBufferPointer { ptr in
            ring.push(
                samples: ptr.baseAddress!,
                count: resampledFramesPerCallback,
                sampleTime: triggerSampleTime,
                hostTime: 0
            )
        }

        XCTAssertTrue(ring.hasDiscontinuity,
            "Domain mismatch (44.1kHz sampleTime + 48kHz count) must trigger discontinuity")
    }

    func testMicCaptureRingFixedDomainNoFalseDiscontinuity() {
        let ring = MicCaptureRing(capacitySamples: 120000)

        // Simulate the FIX: use 48kHz-domain startSampleIndex as sampleTime
        // when resampler is active. Both sampleTime and sampleCount are in 48kHz domain.
        let resampledFramesPerCallback = 4458
        let samples = [Float](repeating: 0.1, count: resampledFramesPerCallback)

        var sampleIndex: Int64 = 0
        for _ in 0..<20 {
            samples.withUnsafeBufferPointer { ptr in
                ring.push(
                    samples: ptr.baseAddress!,
                    count: resampledFramesPerCallback,
                    sampleTime: Float64(sampleIndex),
                    hostTime: 0
                )
            }
            sampleIndex += Int64(resampledFramesPerCallback)
        }

        XCTAssertFalse(ring.hasDiscontinuity,
            "Consistent 48kHz domain (sampleTime + count) must not trigger false discontinuity")
    }

    func testSynchronizerStabilizesWithResampledMicTimeDomain() {
        let config = AudioSynchronizer.TimingConfig(
            minNoDiscontinuitySeconds: 0.0,
            discontinuityDebounceSeconds: 0.0
        )
        let synchronizer = AudioSynchronizer(timingConfig: config)

        let silence = [Float](repeating: 0, count: 480)

        // Build render lead of ~200ms (20 frames of 10ms each)
        for i in 0..<20 {
            silence.withUnsafeBufferPointer { ptr in
                synchronizer.pushRender(
                    samples: ptr.baseAddress!, count: 480,
                    sampleTime: Float64(i * 480), hostTime: 0
                )
            }
        }

        // Push capture using 48kHz-domain sample index (the fix).
        // Use larger chunks (~4458 samples) to simulate resampled mic delivery.
        let captureChunk = [Float](repeating: 0, count: 4458)
        var captureIndex: Int64 = 0
        captureChunk.withUnsafeBufferPointer { ptr in
            synchronizer.pushCapture(
                samples: ptr.baseAddress!, count: 4458,
                sampleTime: Float64(captureIndex), hostTime: 0
            )
        }
        captureIndex += 4458

        let frame = synchronizer.getAlignedFrame()
        XCTAssertNotNil(frame, "Synchronizer should stabilize with consistent 48kHz capture domain")

        let stats = synchronizer.getStats()
        XCTAssertEqual(stats.discontinuities, 0,
            "No discontinuities should occur with consistent timing domain")
    }
}
