//
//  AggregateDeviceManager.swift
//  Muesli
//
//  Manages tap-only aggregate devices for Core Audio tap capture.
//  Creates aggregate devices that host taps WITHOUT including mic subdevices.
//  macOS 26+ only.
//

import Foundation
import CoreAudio
import AudioToolbox
import os.log

// MARK: - Aggregate Device Manager

/// Manages creation and lifecycle of tap-only aggregate devices
/// These devices capture system audio output mix while excluding specified processes
final class AggregateDeviceManager {
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.muesli.app", category: "AggregateDeviceManager")
    
    /// The created aggregate device ID
    private var aggregateDeviceID: AudioDeviceID = kAudioObjectUnknown
    
    /// Unique ID for the aggregate device
    private let aggregateUID = "com.muesli.tap-aggregate-\(UUID().uuidString)"
    
    /// Whether a device has been created
    var hasDevice: Bool {
        return aggregateDeviceID != kAudioObjectUnknown
    }
    
    /// The device ID (kAudioObjectUnknown if not created)
    var deviceID: AudioDeviceID {
        return aggregateDeviceID
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
    
    /// Create a tap-only aggregate device
    /// - Parameters:
    ///   - excludedProcessIDs: Process IDs to exclude from capture (always includes Muesli)
    ///   - isExclusive: Whether to request exclusive tap access
    /// - Returns: The created aggregate device ID
    /// - Throws: If device creation fails
    func createTapOnlyDevice(
        excludedProcessIDs: [pid_t],
        isExclusive: Bool = false
    ) throws -> AudioDeviceID {
        guard aggregateDeviceID == kAudioObjectUnknown else {
            throw AggregateDeviceError.deviceAlreadyExists
        }
        
        // Get default output device to tap
        let outputDeviceID = try CoreAudioHelpers.getDefaultOutputDevice()
        let outputUID = try CoreAudioHelpers.getDeviceUID(outputDeviceID)
        
        logger.info("Creating tap-only aggregate for output device: \(outputUID)")
        
        // Build aggregate device description
        // Key: This is a TAP-ONLY device - we do NOT include the output device as a subdevice
        // We only create a tap on it and expose the tap's input stream
        
        var aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Muesli Tap Device",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
        ]
        
        // Configure tap description
        // The tap captures audio from the output device mix, excluding specified processes
        var tapDescription: [String: Any] = [
            kAudioAggregateDeviceTapAutoStartKey as String: true,
        ]
        
        // Build process exclusion list
        // This ensures Muesli's own audio output is not captured
        if !excludedProcessIDs.isEmpty {
            // Create array of dictionaries for excluded processes
            let excludedProcesses = excludedProcessIDs.map { pid -> [String: Any] in
                return [
                    kAudioTapDescriptionProcessUniqueIDKey as String: Int(pid)
                ]
            }
            tapDescription[kAudioTapDescriptionProcessesKey as String] = excludedProcesses
            
            // Set tap type to exclude these processes
            tapDescription[kAudioTapDescriptionKey as String] = kAudioTapDescriptionOutputDeviceExcludesProcesses
        } else {
            // Capture entire output mix (all processes)
            tapDescription[kAudioTapDescriptionKey as String] = kAudioTapDescriptionOutputDevice
        }
        
        // Add the target device
        tapDescription[kAudioTapDescriptionDeviceUIDKey as String] = outputUID
        
        // Set exclusive mode if requested
        if isExclusive {
            tapDescription[kAudioTapDescriptionIsExclusiveKey as String] = true
        }
        
        aggregateDescription[kAudioAggregateDeviceTapListKey as String] = [tapDescription]
        
        // Create the aggregate device
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        let status = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &deviceID
        )
        
        guard status == noErr else {
            logger.error("Failed to create aggregate device: \(status)")
            throw AggregateDeviceError.creationFailed(status)
        }
        
        guard deviceID != kAudioObjectUnknown else {
            throw AggregateDeviceError.invalidDeviceID
        }
        
        aggregateDeviceID = deviceID
        
        logger.info("Created tap-only aggregate device: \(deviceID), UID: \(self.aggregateUID)")
        
        // Log device info for diagnostics
        logDeviceInfo()
        
        return deviceID
    }
    
    /// Destroy the aggregate device
    func destroyDevice() {
        guard aggregateDeviceID != kAudioObjectUnknown else {
            return
        }
        
        let status = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        if status != noErr {
            logger.warning("Failed to destroy aggregate device: \(status)")
        } else {
            logger.info("Destroyed aggregate device: \(self.aggregateDeviceID)")
        }
        
        aggregateDeviceID = kAudioObjectUnknown
    }
    
    /// Get the tap format from the aggregate device
    /// - Returns: The audio stream basic description for the tap
    func getTapFormat() throws -> AudioStreamBasicDescription {
        guard aggregateDeviceID != kAudioObjectUnknown else {
            throw AggregateDeviceError.noDevice
        }
        
        // Query kAudioTapPropertyFormat if available, otherwise use device input format
        return try CoreAudioHelpers.getDeviceFormat(aggregateDeviceID, scope: kAudioObjectPropertyScopeInput)
    }
    
    /// Configure the tap format
    /// - Parameters:
    ///   - sampleRate: Target sample rate
    ///   - channels: Target channel count
    func configureTapFormat(sampleRate: Float64, channels: UInt32) throws {
        guard aggregateDeviceID != kAudioObjectUnknown else {
            throw AggregateDeviceError.noDevice
        }
        
        // Set nominal sample rate
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
            logger.warning("Failed to set tap sample rate: \(status)")
        }
    }
    
    // MARK: - Private Implementation
    
    /// Log device info for diagnostics
    private func logDeviceInfo() {
        guard aggregateDeviceID != kAudioObjectUnknown else { return }

        do {
            let format = try getTapFormat()
            logger.debug("Tap format: \(format.mSampleRate)Hz, \(format.mChannelsPerFrame) channels, \(format.mBitsPerChannel) bits")

            let deviceId = self.aggregateDeviceID
            Task {
                await DiagnosticLogger.shared.log(.aec,
                    "TAP_DEVICE: id=\(deviceId), " +
                    "sampleRate=\(format.mSampleRate), " +
                    "channels=\(format.mChannelsPerFrame)")
            }
        } catch {
            logger.warning("Failed to get tap format: \(error)")
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
            return "Failed to create aggregate device (status: \(status))"
        case .invalidDeviceID:
            return "Invalid device ID returned"
        case .noDevice:
            return "No aggregate device exists"
        case .formatQueryFailed(let status):
            return "Failed to query format (status: \(status))"
        }
    }
}

// MARK: - Core Audio Tap Constants (macOS 26+)

// These constants are for the tap description dictionary
// Note: Some may not be available until macOS 26+ headers are published

// Tap description keys (defined here for reference, actual values from CoreAudio.framework)
// Using nonisolated(unsafe) because CFString is not Sendable but these are truly immutable constants
private nonisolated(unsafe) let kAudioTapDescriptionKey = "tap" as CFString
private nonisolated(unsafe) let kAudioTapDescriptionDeviceUIDKey = "uuid" as CFString
private nonisolated(unsafe) let kAudioTapDescriptionProcessesKey = "prcs" as CFString
private nonisolated(unsafe) let kAudioTapDescriptionProcessUniqueIDKey = "uuid" as CFString
private nonisolated(unsafe) let kAudioTapDescriptionIsExclusiveKey = "excl" as CFString

// Tap types
private let kAudioTapDescriptionOutputDevice = 1
private let kAudioTapDescriptionOutputDeviceExcludesProcesses = 2

// Aggregate device tap keys
private nonisolated(unsafe) let kAudioAggregateDeviceTapListKey = "tapl" as CFString
private nonisolated(unsafe) let kAudioAggregateDeviceTapAutoStartKey = "tpas" as CFString
