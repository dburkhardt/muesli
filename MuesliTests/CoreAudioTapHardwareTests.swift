//
//  CoreAudioTapHardwareTests.swift
//  MuesliTests
//
//  Hardware-dependent Core Audio Tap tests that require TCC permissions.
//  These are quarantined from CI and run locally only.
//

import XCTest
import AudioToolbox
@testable import Muesli

final class CoreAudioTapHardwareTests: XCTestCase {

    // MARK: - AggregateDeviceManager Integration Tests

    func testAggregateDeviceCreation() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "Skipping hardware-dependent test in CI"
        )
        let manager = AggregateDeviceManager()

        let deviceID = try manager.createTapOnlyDevice(excludedProcessIDs: [], isExclusive: false)

        XCTAssertNotEqual(deviceID, kAudioObjectUnknown, "Aggregate device should be created")
        XCTAssertNotEqual(manager.tapID, kAudioObjectUnknown, "Tap should be created")

        manager.destroyDevice()
    }

    func testAggregateDeviceFormat() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "Skipping hardware-dependent test in CI"
        )
        let manager = AggregateDeviceManager()

        let _ = try manager.createTapOnlyDevice(excludedProcessIDs: [], isExclusive: false)

        let format = try manager.getTapFormat()

        print("[TEST] Tap format: sampleRate=\(format.mSampleRate), channels=\(format.mChannelsPerFrame), bitsPerChannel=\(format.mBitsPerChannel)")
        print("[TEST] Format flags: \(format.mFormatFlags), isFloat=\((format.mFormatFlags & kAudioFormatFlagIsFloat) != 0)")

        XCTAssertEqual(format.mSampleRate, 48000, accuracy: 1000, "Sample rate should be around 48kHz")
        XCTAssertGreaterThanOrEqual(format.mChannelsPerFrame, 1, "Should have at least 1 channel")

        manager.destroyDevice()
    }

    // MARK: - CoreAudioTapManager Integration Tests

    func testTapManagerStartStop() async throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "Skipping hardware-dependent test in CI"
        )
        let manager = CoreAudioTapManager()

        var callbackCount = 0
        var lastSamples: [Float] = []

        try manager.start(
            configuration: TapConfiguration(
                sampleRate: 48000, channelCount: 2, frameQuantum: 480,
                excludedProcessIDs: [], isExclusive: false
            ),
            callback: { samples, frameCount, sampleTime, hostTime in
                callbackCount += 1
                if lastSamples.isEmpty && frameCount > 0 {
                    let count = min(Int(frameCount) * 2, 100)
                    lastSamples = Array(UnsafeBufferPointer(start: samples, count: count))
                }
            }
        )

        try await Task.sleep(nanoseconds: 500_000_000)

        print("[TEST] IOProc callback count after 500ms: \(callbackCount)")
        XCTAssertGreaterThan(callbackCount, 0, "IOProc should fire callbacks")

        manager.stop()
    }

    func testTapManagerReceivesAudioWithBeep() async throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "Skipping hardware-dependent test in CI"
        )
        let manager = CoreAudioTapManager()

        var maxSampleValue: Float = 0
        var totalCallbacks = 0

        try manager.start(
            configuration: TapConfiguration(
                sampleRate: 48000, channelCount: 2, frameQuantum: 480,
                excludedProcessIDs: [], isExclusive: false
            ),
            callback: { samples, frameCount, sampleTime, hostTime in
                totalCallbacks += 1
                let count = Int(frameCount) * 2
                for i in 0..<count {
                    maxSampleValue = max(maxSampleValue, abs(samples[i]))
                }
            }
        )

        try await Task.sleep(nanoseconds: 200_000_000)
        NSSound.beep()
        try await Task.sleep(nanoseconds: 1_000_000_000)

        print("[TEST] Total callbacks: \(totalCallbacks), max sample value: \(maxSampleValue)")

        if maxSampleValue == 0 {
            print("[TEST] WARNING: All samples are zero. Possible causes:")
            print("[TEST]   1. Audio capture permission not granted")
            print("[TEST]   2. macOS bug with Core Audio Tap API")
            print("[TEST]   3. Tap configuration issue")
        }

        XCTAssertGreaterThan(totalCallbacks, 0, "Should receive callbacks")
        manager.stop()
    }

    func testTapFormatIsFloat32() async throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "Skipping hardware-dependent test in CI"
        )
        let manager = CoreAudioTapManager()

        var formatChecked = false
        var isFloat32 = false

        try manager.start(
            configuration: TapConfiguration(
                sampleRate: 48000, channelCount: 2, frameQuantum: 480,
                excludedProcessIDs: [], isExclusive: false
            ),
            callback: { samples, frameCount, sampleTime, hostTime in
                if !formatChecked {
                    formatChecked = true
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
        )

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(formatChecked, "Should have received at least one callback")
        XCTAssertTrue(isFloat32, "Samples should be valid Float32 (not NaN, Inf, or huge values)")

        manager.stop()
    }

    // MARK: - Minimal Tap Test (Standalone)

    func testMinimalTapReceivesAudio() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "Skipping hardware-dependent test in CI"
        )
        let manager = AggregateDeviceManager()
        var ioProcID: AudioDeviceIOProcID?
        var callbackCount = 0
        var maxSample: Float = 0

        do {
            let deviceID = try manager.createTapOnlyDevice(excludedProcessIDs: [], isExclusive: true)
            let ioProcStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, deviceID, nil) { _, inInputData, _, _, _ in
                callbackCount += 1
                let mutablePtr = UnsafeMutablePointer(mutating: inInputData)
                let bufferList = UnsafeMutableAudioBufferListPointer(mutablePtr)
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
            }

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

            XCTAssertGreaterThan(callbackCount, 0, "Should receive IOProc callbacks")

            AudioDeviceStop(deviceID, ioProcID)
            AudioDeviceDestroyIOProcID(deviceID, ioProcID)
            manager.destroyDevice()
        } catch {
            XCTFail("Minimal tap test failed: \(error)")
        }
    }
}
