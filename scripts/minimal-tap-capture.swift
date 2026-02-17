//
//  minimal-tap-capture.swift
//  Standalone Core Audio tap capture sanity check.
//

import Foundation
import CoreAudio
import AudioToolbox
import AppKit
import CoreGraphics

print("Starting minimal tap capture, screenCaptureAccess=\(CGPreflightScreenCaptureAccess())")

// Create tap description
let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
tapDescription.name = "Muesli Minimal Tap"
tapDescription.uuid = UUID()
tapDescription.isPrivate = true
tapDescription.isExclusive = true
tapDescription.muteBehavior = .unmuted

var tapID: AudioObjectID = kAudioObjectUnknown
let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)
print("Created process tap: status=\(tapStatus), tapID=\(tapID)")

guard tapStatus == noErr, tapID != kAudioObjectUnknown else {
    exit(1)
}

// Query tap format
var format = AudioStreamBasicDescription()
var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
var formatAddress = AudioObjectPropertyAddress(
    mSelector: kAudioTapPropertyFormat,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
let formatStatus = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &format)
print("Tap format: status=\(formatStatus), sampleRate=\(format.mSampleRate), channels=\(format.mChannelsPerFrame), isFloat=\((format.mFormatFlags & kAudioFormatFlagIsFloat) != 0)")

// Fetch tap UID
var uidAddress = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyDeviceUID,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var uid: CFString?
var uidSize = UInt32(MemoryLayout<CFString?>.size)
let uidStatus = AudioObjectGetPropertyData(tapID, &uidAddress, 0, nil, &uidSize, &uid)
let tapUID = (uidStatus == noErr ? (uid as String?) : nil) ?? tapDescription.uuid!.uuidString

// Create aggregate device (tap-only)
let aggregateUID = "com.muesli.tap-cli-\(UUID().uuidString)"
let aggregateDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "Muesli Tap CLI",
    kAudioAggregateDeviceUIDKey: aggregateUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceTapListKey: [
        [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: true
        ]
    ],
    kAudioAggregateDeviceTapAutoStartKey: false
]

var aggregateID: AudioDeviceID = kAudioObjectUnknown
let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &aggregateID)
print("Created aggregate device: status=\(aggregateStatus), aggregateID=\(aggregateID)")

guard aggregateStatus == noErr, aggregateID != kAudioObjectUnknown else {
    AudioHardwareDestroyProcessTap(tapID)
    exit(1)
}

var callbackCount = 0
var maxSample: Float = 0
var ioProcID: AudioDeviceIOProcID?

let ioProcStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, inInputData, _, _, _ in
    callbackCount += 1
    guard let inputData = inInputData else { return }
    let bufferList = UnsafeMutableAudioBufferListPointer(inputData)
    for buffer in bufferList {
        guard let data = buffer.mData else { continue }
        let floatPtr = data.assumingMemoryBound(to: Float.self)
        let sampleCount = min(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size, 200)
        for i in 0..<sampleCount {
            let value = abs(floatPtr[i])
            if value > maxSample {
                maxSample = value
            }
        }
    }
}

guard ioProcStatus == noErr, let ioProcID = ioProcID else {
    AudioHardwareDestroyAggregateDevice(aggregateID)
    AudioHardwareDestroyProcessTap(tapID)
    exit(1)
}

let startStatus = AudioDeviceStart(aggregateID, ioProcID)
print("Started audio device: status=\(startStatus)")

NSSound.beep()
RunLoop.current.run(until: Date().addingTimeInterval(2.0))

print("Final: callbackCount=\(callbackCount), maxSample=\(maxSample), nonZero=\(maxSample > 0.001)")

AudioDeviceStop(aggregateID, ioProcID)
AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
AudioHardwareDestroyAggregateDevice(aggregateID)
AudioHardwareDestroyProcessTap(tapID)
