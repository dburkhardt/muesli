//
//  AggregateDeviceManager.swift
//  Muesli
//
//  Creates and manages Core Audio process taps using the official API:
//  1. AudioHardwareCreateProcessTap + CATapDescription (macOS 14.2+)
//  2. Aggregate device with tap in kAudioAggregateDeviceTapListKey
//

import Foundation
import CoreAudio
import AudioToolbox
import os.log

// MARK: - Aggregate Device Manager

/// Manages creation of aggregate devices that include process taps
/// Uses the two-step approach:
/// 1. Create a process tap with CATapDescription
/// 2. Create an aggregate device that includes the tap
final class AggregateDeviceManager {

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.muesli.app", category: "AggregateDeviceManager")

    /// The created process tap's AudioObjectID
    private var tapObjectID: AudioObjectID = kAudioObjectUnknown

    /// The created aggregate device ID
    private var aggregateDeviceID: AudioDeviceID = kAudioObjectUnknown

    /// Unique ID for the aggregate device
    private let aggregateUID = "com.muesli.tap-aggregate-\(UUID().uuidString)"

    /// Whether a device has been created
    var hasDevice: Bool {
        return aggregateDeviceID != kAudioObjectUnknown
    }

    /// The aggregate device ID (kAudioObjectUnknown if not created)
    var deviceID: AudioDeviceID {
        return aggregateDeviceID
    }
    
    /// The tap object ID (for direct IOProc if needed)
    var tapID: AudioObjectID {
        return tapObjectID
    }

    // MARK: - Initialization

    init() {
        logger.debug("AggregateDeviceManager initialized")
    }

    deinit {
        destroyDevice()
        logger.debug("AggregateDeviceManager deallocated")
    }

    // MARK: - Public API

    /// Create a tap-based aggregate device for system audio capture
    /// - Parameters:
    ///   - excludedProcessIDs: Process IDs to exclude from capture
    ///   - isExclusive: Whether to mute tapped audio
    /// - Returns: The aggregate device ID
    /// - Throws: If creation fails
    func createTapOnlyDevice(
        excludedProcessIDs: [pid_t],
        isExclusive: Bool = false
    ) throws -> AudioDeviceID {
        guard aggregateDeviceID == kAudioObjectUnknown else {
            throw AggregateDeviceError.deviceAlreadyExists
        }

        print("[TAP DEBUG] === Starting tap creation ===")
        print("[TAP DEBUG] Excluding PIDs: \(excludedProcessIDs)")
        logger.info("Creating process tap excluding PIDs: \(excludedProcessIDs)")

        // Step 1: Create the process tap
        let tapID = try createProcessTap(excludedPIDs: excludedProcessIDs, isExclusive: isExclusive)
        tapObjectID = tapID

        print("[TAP DEBUG] Created process tap with ID: \(tapID)")
        logger.info("Created process tap: \(tapID)")

        // Step 2: Get the tap's UID to reference it in the aggregate device
        let tapUID = try getTapUID(tapID)

        print("[TAP DEBUG] Tap UID: \(tapUID)")
        logger.info("Tap UID: \(tapUID)")

        // Step 3: Create aggregate device that includes this tap
        let deviceID = try createAggregateDeviceWithTap(tapUID: tapUID)
        aggregateDeviceID = deviceID

        print("[TAP DEBUG] Created aggregate device with ID: \(deviceID)")
        print("[TAP DEBUG] Aggregate UID: \(self.aggregateUID)")
        logger.info("Created aggregate device: \(deviceID), UID: \(self.aggregateUID)")

        // Log device info for diagnostics
        logDeviceInfo()

        // Verify the tap is attached to the aggregate device
        verifyTapAttachment()

        print("[TAP DEBUG] === Tap creation complete ===")
        return deviceID
    }

    /// Destroy the aggregate device and process tap
    func destroyDevice() {
        // Destroy aggregate device first
        if aggregateDeviceID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if status != noErr {
                logger.warning("Failed to destroy aggregate device: \(status)")
            } else {
                logger.info("Destroyed aggregate device: \(self.aggregateDeviceID)")
            }
            aggregateDeviceID = kAudioObjectUnknown
        }

        // Then destroy the tap
        if tapObjectID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(tapObjectID)
            if status != noErr {
                logger.warning("Failed to destroy process tap: \(status)")
            } else {
                logger.info("Destroyed process tap: \(self.tapObjectID)")
            }
            tapObjectID = kAudioObjectUnknown
        }
    }

    /// Get the device's input format
    func getTapFormat() throws -> AudioStreamBasicDescription {
        guard aggregateDeviceID != kAudioObjectUnknown else {
            throw AggregateDeviceError.noDevice
        }

        return try CoreAudioHelpers.getDeviceFormat(aggregateDeviceID, scope: kAudioObjectPropertyScopeInput)
    }

    /// Configure the tap format (kept for API compatibility)
    func configureTapFormat(sampleRate: Float64, channels: UInt32) throws {
        guard aggregateDeviceID != kAudioObjectUnknown else {
            throw AggregateDeviceError.noDevice
        }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var rate = sampleRate
        let status = AudioObjectSetPropertyData(
            aggregateDeviceID,
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<Float64>.size),
            &rate
        )

        if status != noErr {
            logger.warning("Failed to set sample rate: \(status)")
        }
    }

    // MARK: - Private Implementation

    /// The tap's UUID (set when created)
    private var tapUUID: UUID?

    /// Create a process tap using CATapDescription
    private func createProcessTap(excludedPIDs: [pid_t], isExclusive: Bool) throws -> AudioObjectID {
        // Convert PIDs to process AudioObjectIDs
        print("[TAP DEBUG] Converting PIDs to process AudioObjectIDs...")
        let processObjectIDs: [AudioObjectID] = excludedPIDs.compactMap { pid in
            let objID = getProcessObjectID(for: pid)
            print("[TAP DEBUG]   PID \(pid) -> AudioObjectID \(objID ?? 0)")
            return objID
        }

        if processObjectIDs.count < excludedPIDs.count {
            print("[TAP DEBUG] WARNING: Could not find process objects for some PIDs")
            logger.warning("Could not find process objects for some PIDs")
        }

        // Create tap description
        print("[TAP DEBUG] Creating CATapDescription...")
        let tapDescription: CATapDescription
        if processObjectIDs.isEmpty {
            // Global tap - capture all system audio
            print("[TAP DEBUG] Creating global tap (no exclusions)")
            tapDescription = CATapDescription()
            tapDescription.isMono = false
            tapDescription.isMixdown = true
        } else {
            // Exclude specified processes
            print("[TAP DEBUG] Creating tap excluding \(processObjectIDs.count) process(es)")
            tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: processObjectIDs)
        }

        // Configure tap
        tapDescription.name = "Muesli System Audio Tap"
        let uuid = UUID()
        tapDescription.uuid = uuid
        tapUUID = uuid
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = isExclusive ? .muted : .unmuted

        print("[TAP DEBUG] Tap config: name='\(tapDescription.name ?? "nil")', uuid=\(uuid), isPrivate=\(tapDescription.isPrivate), muteBehavior=\(tapDescription.muteBehavior.rawValue)")
        print("[TAP DEBUG] Tap config: isMono=\(tapDescription.isMono), isMixdown=\(tapDescription.isMixdown), isExclusive=\(tapDescription.isExclusive)")

        // Create the tap
        print("[TAP DEBUG] Calling AudioHardwareCreateProcessTap...")
        var newTapID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateProcessTap(tapDescription, &newTapID)

        print("[TAP DEBUG] AudioHardwareCreateProcessTap returned status: \(status), tapID: \(newTapID)")

        guard status == noErr else {
            print("[TAP DEBUG] ERROR: AudioHardwareCreateProcessTap failed with status \(status)")
            logger.error("AudioHardwareCreateProcessTap failed: \(status)")
            throw AggregateDeviceError.creationFailed(status)
        }

        guard newTapID != kAudioObjectUnknown else {
            print("[TAP DEBUG] ERROR: Tap ID is kAudioObjectUnknown")
            throw AggregateDeviceError.invalidDeviceID
        }

        return newTapID
    }

    /// Get the UID of the tap from the system
    private func getTapUID(_ tapID: AudioObjectID) throws -> String {
        // Query the tap's UID property
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uid: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)

        let status = AudioObjectGetPropertyData(
            tapID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &uid
        )

        guard status == noErr, let tapUID = uid as String? else {
            // Fallback: try using the UUID we set
            if let uuid = tapUUID {
                logger.warning("Could not query tap UID (status \(status)), using UUID: \(uuid.uuidString)")
                return uuid.uuidString
            }
            throw AggregateDeviceError.formatQueryFailed(status)
        }

        return tapUID
    }

    /// Create an aggregate device that includes the tap
    private func createAggregateDeviceWithTap(tapUID: String) throws -> AudioDeviceID {
        // Get default output device to use as clock source
        // An aggregate device with only a tap has no clock, so IOProc callbacks won't fire
        let outputDeviceID = try CoreAudioHelpers.getDefaultOutputDevice()
        let outputDeviceUID = try CoreAudioHelpers.getDeviceUID(outputDeviceID)
        
        print("[TAP DEBUG] Using default output device as clock source: \(outputDeviceUID)")
        logger.info("Using default output device as clock source: \(outputDeviceUID)")
        
        // Build aggregate device description
        // Reference: AudioHardware.h lines 1626-1645
        // 
        // APPROACH: Use kAudioAggregateDeviceClockDeviceKey to set clock source
        // WITHOUT adding the output device as a sub-device. This way:
        // - The tap provides the only input streams
        // - The output device provides clock timing
        // - No extra output streams pollute the aggregate
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Muesli Tap Device",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // Use clock device key instead of sub-device
            kAudioAggregateDeviceClockDeviceKey: outputDeviceUID,
            // Include the tap - key is "taps" per AudioHardware.h line 1632
            kAudioAggregateDeviceTapListKey: [tapUID],
            // Auto-start the tap - key is "tapautostart" per AudioHardware.h line 1645
            kAudioAggregateDeviceTapAutoStartKey: true
        ]
        
        // #region agent log
        let logPayload: [String: Any] = ["location": "AggregateDeviceManager.swift:298", "message": "Creating aggregate with clock device (no sub-device)", "data": ["outputDeviceUID": outputDeviceUID, "tapUID": tapUID, "aggregateUID": aggregateUID], "timestamp": Date().timeIntervalSince1970 * 1000, "sessionId": "debug-session", "hypothesisId": "H"]
        if let jsonData = try? JSONSerialization.data(withJSONObject: logPayload), let jsonStr = String(data: jsonData, encoding: .utf8) {
            if let handle = FileHandle(forWritingAtPath: "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log") {
                handle.seekToEndOfFile()
                handle.write((jsonStr + "\n").data(using: .utf8)!)
                handle.closeFile()
            } else {
                try? (jsonStr + "\n").write(toFile: "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log", atomically: false, encoding: .utf8)
            }
        }
        // #endregion

        var deviceID: AudioDeviceID = kAudioObjectUnknown
        let status = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &deviceID
        )

        guard status == noErr else {
            logger.error("AudioHardwareCreateAggregateDevice failed: \(status)")
            throw AggregateDeviceError.creationFailed(status)
        }

        guard deviceID != kAudioObjectUnknown else {
            throw AggregateDeviceError.invalidDeviceID
        }

        return deviceID
    }

    /// Get the AudioObjectID for a process by PID
    private func getProcessObjectID(for pid: pid_t) -> AudioObjectID? {
        // Use kAudioHardwarePropertyTranslatePIDToProcessObject
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var processObjectID: AudioObjectID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var pidValue = pid

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            UInt32(MemoryLayout<pid_t>.size),
            &pidValue,
            &dataSize,
            &processObjectID
        )

        if status == noErr && processObjectID != kAudioObjectUnknown {
            return processObjectID
        }

        return nil
    }

    /// Log device info for diagnostics
    private func logDeviceInfo() {
        guard aggregateDeviceID != kAudioObjectUnknown else { return }

        do {
            let format = try getTapFormat()
            print("[TAP DEBUG] Tap format: \(format.mSampleRate)Hz, \(format.mChannelsPerFrame) channels, \(format.mBitsPerChannel) bits")
            print("[TAP DEBUG] Format flags: \(format.mFormatFlags), bytes/frame: \(format.mBytesPerFrame)")
            logger.debug("Tap format: \(format.mSampleRate)Hz, \(format.mChannelsPerFrame) channels, \(format.mBitsPerChannel) bits")

            let deviceId = self.aggregateDeviceID
            let tapId = self.tapObjectID
            Task {
                await DiagnosticLogger.shared.log(.aec,
                    "TAP_DEVICE: aggregateId=\(deviceId), tapId=\(tapId), " +
                    "sampleRate=\(format.mSampleRate), " +
                    "channels=\(format.mChannelsPerFrame)")
            }
        } catch {
            print("[TAP DEBUG] ERROR: Failed to get tap format: \(error)")
            logger.warning("Failed to get tap format: \(error)")
        }
    }

    /// Verify that the tap is properly attached to the aggregate device
    private func verifyTapAttachment() {
        guard aggregateDeviceID != kAudioObjectUnknown else {
            print("[TAP DEBUG] ERROR: No aggregate device to verify")
            return
        }

        // Check if the aggregate device has input streams
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            aggregateDeviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        if status == noErr {
            let streamCount = Int(dataSize) / MemoryLayout<AudioStreamID>.size
            print("[TAP DEBUG] Aggregate device has \(streamCount) input stream(s)")

            if streamCount > 0 {
                var streams = [AudioStreamID](repeating: 0, count: streamCount)
                status = AudioObjectGetPropertyData(
                    aggregateDeviceID,
                    &propertyAddress,
                    0,
                    nil,
                    &dataSize,
                    &streams
                )
                if status == noErr {
                    for (index, streamID) in streams.enumerated() {
                        print("[TAP DEBUG]   Stream \(index): ID=\(streamID)")
                    }
                }
            }
        } else {
            print("[TAP DEBUG] ERROR: Could not query input streams: \(status)")
        }

        // Check tap list on the aggregate device
        var tapListAddress = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyTapList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var tapListSize: UInt32 = 0
        status = AudioObjectGetPropertyDataSize(
            aggregateDeviceID,
            &tapListAddress,
            0,
            nil,
            &tapListSize
        )

        if status == noErr && tapListSize > 0 {
            let tapCount = Int(tapListSize) / MemoryLayout<AudioObjectID>.size
            print("[TAP DEBUG] Aggregate device has \(tapCount) tap(s) in tap list")

            var taps = [AudioObjectID](repeating: kAudioObjectUnknown, count: tapCount)
            status = AudioObjectGetPropertyData(
                aggregateDeviceID,
                &tapListAddress,
                0,
                nil,
                &tapListSize,
                &taps
            )
            if status == noErr {
                for (index, tapId) in taps.enumerated() {
                    print("[TAP DEBUG]   Tap \(index): ID=\(tapId)")
                }
            }
        } else {
            print("[TAP DEBUG] WARNING: No taps in aggregate device tap list (status: \(status), size: \(tapListSize))")
        }

        // Check if device is running
        var isRunningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var isRunning: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        status = AudioObjectGetPropertyData(
            aggregateDeviceID,
            &isRunningAddress,
            0,
            nil,
            &runningSize,
            &isRunning
        )

        if status == noErr {
            print("[TAP DEBUG] Aggregate device isRunning: \(isRunning != 0)")
        }
    }
}

// MARK: - Errors

enum AggregateDeviceError: Error, LocalizedError {
    case deviceAlreadyExists
    case creationFailed(OSStatus)
    case invalidDeviceID
    case noDevice
    case formatQueryFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .deviceAlreadyExists:
            return "Aggregate device already exists"
        case .creationFailed(let status):
            return "Failed to create device (status: \(status))"
        case .invalidDeviceID:
            return "Invalid device ID returned"
        case .noDevice:
            return "No aggregate device exists"
        case .formatQueryFailed(let status):
            return "Failed to query format (status: \(status))"
        }
    }
}
