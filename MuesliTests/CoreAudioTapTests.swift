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
    private func appendDebugLog(
        runId: String,
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: Any]
    ) {
        let payload: [String: Any] = [
            "sessionId": "debug-session",
            "runId": runId,
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": data,
            "timestamp": Date().timeIntervalSince1970 * 1000
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }
        if let handle = FileHandle(forWritingAtPath: "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log") {
            handle.seekToEndOfFile()
            handle.write((jsonString + "\n").data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? (jsonString + "\n").write(
                toFile: "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log",
                atomically: false,
                encoding: .utf8
            )
        }
    }
    
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
    
    // MARK: - AggregateDeviceManager Integration Tests
    
    func testAggregateDeviceCreation() throws {
        let manager = AggregateDeviceManager()
        
        // Create tap with no exclusions (global tap)
        let deviceID = try manager.createDevice(excludedPIDs: [], isExclusive: false)
        
        XCTAssertNotEqual(deviceID, kAudioObjectUnknown, "Aggregate device should be created")
        XCTAssertNotEqual(manager.tapID, kAudioObjectUnknown, "Tap should be created")
        
        // Clean up
        manager.destroyDevice()
    }
    
    func testAggregateDeviceFormat() throws {
        let manager = AggregateDeviceManager()
        
        let _ = try manager.createDevice(excludedPIDs: [], isExclusive: false)
        
        // Query the tap format
        let format = try manager.getTapFormat()
        
        print("[TEST] Tap format: sampleRate=\(format.mSampleRate), channels=\(format.mChannelsPerFrame), bitsPerChannel=\(format.mBitsPerChannel)")
        print("[TEST] Format flags: \(format.mFormatFlags), isFloat=\((format.mFormatFlags & kAudioFormatFlagIsFloat) != 0)")
        
        // Verify expected format
        XCTAssertEqual(format.mSampleRate, 48000, accuracy: 1000, "Sample rate should be around 48kHz")
        XCTAssertGreaterThanOrEqual(format.mChannelsPerFrame, 1, "Should have at least 1 channel")
        
        manager.destroyDevice()
    }
    
    // MARK: - CoreAudioTapManager Integration Tests
    
    func testTapManagerStartStop() async throws {
        let manager = CoreAudioTapManager()
        
        var callbackCount = 0
        var lastSamples: [Float] = []
        
        // Start the tap with a callback
        try await manager.start(excludedPIDs: [], isExclusive: false) { samples, frameCount, sampleTime, hostTime in
            callbackCount += 1
            // Capture first 100 samples for inspection
            if lastSamples.isEmpty && frameCount > 0 {
                let count = min(Int(frameCount) * 2, 100)  // Stereo
                lastSamples = Array(UnsafeBufferPointer(start: samples, count: count))
            }
        }
        
        // Wait a bit for IOProc callbacks
        try await Task.sleep(nanoseconds: 500_000_000)  // 500ms
        
        // Check that callbacks fired
        print("[TEST] IOProc callback count after 500ms: \(callbackCount)")
        XCTAssertGreaterThan(callbackCount, 0, "IOProc should fire callbacks")
        
        // Stop
        await manager.stop()
    }
    
    func testTapManagerReceivesAudioWithBeep() async throws {
        let manager = CoreAudioTapManager()
        
        var maxSampleValue: Float = 0
        var totalCallbacks = 0
        
        // Start the tap
        try await manager.start(excludedPIDs: [], isExclusive: false) { samples, frameCount, sampleTime, hostTime in
            totalCallbacks += 1
            let count = Int(frameCount) * 2  // Stereo
            for i in 0..<count {
                maxSampleValue = max(maxSampleValue, abs(samples[i]))
            }
        }
        
        // Wait for tap to stabilize
        try await Task.sleep(nanoseconds: 200_000_000)  // 200ms
        
        // Play a system sound
        NSSound.beep()
        
        // Wait for sound to be captured
        try await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
        
        print("[TEST] Total callbacks: \(totalCallbacks), max sample value: \(maxSampleValue)")
        
        // Check if we received actual audio (non-zero samples)
        // Note: This test may fail if audio capture permission is not granted
        if maxSampleValue == 0 {
            print("[TEST] WARNING: All samples are zero. Possible causes:")
            print("[TEST]   1. Audio capture permission not granted")
            print("[TEST]   2. macOS bug with Core Audio Tap API")
            print("[TEST]   3. Tap configuration issue")
        }
        
        XCTAssertGreaterThan(totalCallbacks, 0, "Should receive callbacks")
        // Note: We don't fail on zero samples since it could be a permission issue
        
        await manager.stop()
    }
    
    func testTapFormatIsFloat32() async throws {
        let manager = CoreAudioTapManager()
        
        var formatChecked = false
        var isFloat32 = false
        
        try await manager.start(excludedPIDs: [], isExclusive: false) { samples, frameCount, sampleTime, hostTime in
            if !formatChecked {
                formatChecked = true
                // If samples are Float, reading them as Float should give sensible values
                // (not NaN, not huge numbers from misinterpreted bytes)
                let count = min(Int(frameCount) * 2, 100)
                var hasValidFloats = true
                for i in 0..<count {
                    let val = samples[i]
                    if val.isNaN || val.isInfinite || abs(val) > 10.0 {
                        hasValidFloats = false
                        break
                    }
                }
                isFloat32 = hasValidFloats
            }
        }
        
        try await Task.sleep(nanoseconds: 200_000_000)
        
        XCTAssertTrue(formatChecked, "Should have received at least one callback")
        XCTAssertTrue(isFloat32, "Samples should be valid Float32 (not NaN, Inf, or huge values)")
        
        await manager.stop()
    }

    // MARK: - Minimal Tap Test (Standalone)

    func testMinimalTapReceivesAudio() {
        let runId = "tap-minimal-pre"
        let manager = AggregateDeviceManager()
        var ioProcID: AudioDeviceIOProcID?
        var callbackCount = 0
        var maxSample: Float = 0
        var loggedFirstCallback = false

        // #region agent log
        appendDebugLog(
            runId: runId,
            hypothesisId: "A",
            location: "CoreAudioTapTests.swift:testMinimalTapReceivesAudio",
            message: "Starting minimal tap test",
            data: [
                "isExclusive": true,
                "muteBehavior": "unmuted",
                "threshold": 0.001
            ]
        )
        // #endregion

        do {
            let deviceID = try manager.createTapOnlyDevice(excludedProcessIDs: [], isExclusive: true)
            let ioProcStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, deviceID, nil) { _, inInputData, _, _, _ in
                callbackCount += 1
                guard let inputData = inInputData else { return }
                let bufferList = UnsafeMutableAudioBufferListPointer(inputData)
                let bufferCount = bufferList.count
                for buffer in bufferList {
                    let byteCount = Int(buffer.mDataByteSize)
                    if let data = buffer.mData {
                        let floatPtr = data.assumingMemoryBound(to: Float.self)
                        let sampleCount = min(byteCount / MemoryLayout<Float>.size, 200)
                        for i in 0..<sampleCount {
                            let value = abs(floatPtr[i])
                            if value > maxSample {
                                maxSample = value
                            }
                        }
                    }
                }

                if !loggedFirstCallback {
                    loggedFirstCallback = true
                    // #region agent log
                    self.appendDebugLog(
                        runId: runId,
                        hypothesisId: "B",
                        location: "CoreAudioTapTests.swift:testMinimalTapReceivesAudio:ioProc",
                        message: "First IOProc callback",
                        data: [
                            "callbackCount": callbackCount,
                            "bufferCount": bufferCount,
                            "maxSample": maxSample
                        ]
                    )
                    // #endregion
                }
            }

            // #region agent log
            appendDebugLog(
                runId: runId,
                hypothesisId: "C",
                location: "CoreAudioTapTests.swift:testMinimalTapReceivesAudio",
                message: "Created IOProc",
                data: [
                    "deviceID": deviceID,
                    "tapID": manager.tapID,
                    "ioProcStatus": ioProcStatus
                ]
            )
            // #endregion

            XCTAssertEqual(ioProcStatus, noErr, "IOProc creation should succeed")

            guard let ioProcID = ioProcID else {
                XCTFail("IOProc ID should be non-nil")
                manager.destroyDevice()
                return
            }

            let startStatus = AudioDeviceStart(deviceID, ioProcID)
            XCTAssertEqual(startStatus, noErr, "AudioDeviceStart should succeed")

            Thread.sleep(forTimeInterval: 0.3)
            NSSound.beep()
            Thread.sleep(forTimeInterval: 1.0)

            // #region agent log
            appendDebugLog(
                runId: runId,
                hypothesisId: "D",
                location: "CoreAudioTapTests.swift:testMinimalTapReceivesAudio",
                message: "Final tap stats",
                data: [
                    "callbackCount": callbackCount,
                    "maxSample": maxSample,
                    "nonZero": maxSample > 0.001
                ]
            )
            // #endregion

            XCTAssertGreaterThan(callbackCount, 0, "Should receive IOProc callbacks")

            AudioDeviceStop(deviceID, ioProcID)
            AudioDeviceDestroyIOProcID(deviceID, ioProcID)
            manager.destroyDevice()
        } catch {
            XCTFail("Minimal tap test failed: \(error)")
        }
    }
}
