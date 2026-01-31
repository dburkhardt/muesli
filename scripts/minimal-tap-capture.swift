//
//  minimal-tap-capture.swift
//  Standalone Core Audio tap capture sanity check.
//

import Foundation
import CoreAudio
import AudioToolbox
import AppKit
import CoreGraphics

let logPath = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
let sessionId = "debug-session"
let runId = "tap-cli-pre"

func appendDebugLog(hypothesisId: String, location: String, message: String, data: [String: Any]) {
    // #region agent log
    let payload: [String: Any] = [
        "sessionId": sessionId,
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
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write((jsonString + "\n").data(using: .utf8)!)
        handle.closeFile()
    } else {
        try? (jsonString + "\n").write(toFile: logPath, atomically: false, encoding: .utf8)
    }
    // #endregion
}

appendDebugLog(
    hypothesisId: "A",
    location: "minimal-tap-capture.swift:start",
    message: "Starting minimal tap capture",
    data: [
        "screenCaptureAccess": CGPreflightScreenCaptureAccess()
    ]
)

// Create tap description
let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
tapDescription.name = "Muesli Minimal Tap"
tapDescription.uuid = UUID()
tapDescription.isPrivate = true
tapDescription.isExclusive = true
tapDescription.muteBehavior = .unmuted

var tapID: AudioObjectID = kAudioObjectUnknown
let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)

appendDebugLog(
    hypothesisId: "A",
    location: "minimal-tap-capture.swift:createTap",
    message: "Created process tap",
    data: [
        "status": tapStatus,
        "tapID": tapID,
        "isExclusive": tapDescription.isExclusive,
        "muteBehavior": tapDescription.muteBehavior.rawValue
    ]
)

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

appendDebugLog(
    hypothesisId: "C",
    location: "minimal-tap-capture.swift:tapFormat",
    message: "Tap format queried",
    data: [
        "status": formatStatus,
        "sampleRate": format.mSampleRate,
        "channels": format.mChannelsPerFrame,
        "formatFlags": format.mFormatFlags,
        "isFloat": (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    ]
)

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

appendDebugLog(
    hypothesisId: "A",
    location: "minimal-tap-capture.swift:createAggregate",
    message: "Created aggregate device",
    data: [
        "status": aggregateStatus,
        "aggregateID": aggregateID,
        "tapUID": tapUID
    ]
)

guard aggregateStatus == noErr, aggregateID != kAudioObjectUnknown else {
    AudioHardwareDestroyProcessTap(tapID)
    exit(1)
}

var callbackCount = 0
var maxSample: Float = 0
var loggedFirst = false
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
        if !loggedFirst {
            loggedFirst = true
            appendDebugLog(
                hypothesisId: "B",
                location: "minimal-tap-capture.swift:ioProc",
                message: "First IOProc callback",
                data: [
                    "callbackCount": callbackCount,
                    "bufferBytes": buffer.mDataByteSize,
                    "channels": buffer.mNumberChannels,
                    "maxSample": maxSample
                ]
            )
        }
    }
}

appendDebugLog(
    hypothesisId: "A",
    location: "minimal-tap-capture.swift:createIOProc",
    message: "Created IOProc",
    data: [
        "status": ioProcStatus
    ]
)

guard ioProcStatus == noErr, let ioProcID = ioProcID else {
    AudioHardwareDestroyAggregateDevice(aggregateID)
    AudioHardwareDestroyProcessTap(tapID)
    exit(1)
}

let startStatus = AudioDeviceStart(aggregateID, ioProcID)
appendDebugLog(
    hypothesisId: "A",
    location: "minimal-tap-capture.swift:startDevice",
    message: "Started audio device",
    data: [
        "status": startStatus
    ]
)

NSSound.beep()
RunLoop.current.run(until: Date().addingTimeInterval(2.0))

appendDebugLog(
    hypothesisId: "D",
    location: "minimal-tap-capture.swift:final",
    message: "Final tap stats",
    data: [
        "callbackCount": callbackCount,
        "maxSample": maxSample,
        "nonZero": maxSample > 0.001
    ]
)

AudioDeviceStop(aggregateID, ioProcID)
AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
AudioHardwareDestroyAggregateDevice(aggregateID)
AudioHardwareDestroyProcessTap(tapID)
