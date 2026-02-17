//
//  CoreAudioHelpers.swift
//  Muesli
//
//  Core Audio utility functions for tap management
//

import Foundation
import CoreAudio
import os.log

private let logger = Logger(subsystem: "com.dburkhardt.muesli", category: "CoreAudioHelpers")

enum CoreAudioError: Error {
    case deviceNotFound
    case propertyNotFound
    case invalidPropertyData
    case apiError(OSStatus)

    var localizedDescription: String {
        switch self {
        case .deviceNotFound:
            return "Audio device not found"
        case .propertyNotFound:
            return "Audio property not found"
        case .invalidPropertyData:
            return "Invalid audio property data"
        case .apiError(let status):
            return "Core Audio error: \(status)"
        }
    }
}

/// Core Audio utility functions
struct CoreAudioHelpers {

    // MARK: - Device Discovery

    /// Get the default output device ID
    static func getDefaultOutputDevice() throws -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        guard status == noErr else {
            throw CoreAudioError.apiError(status)
        }

        guard deviceID != kAudioObjectUnknown else {
            throw CoreAudioError.deviceNotFound
        }

        return deviceID
    }

    /// Get the default input device ID
    static func getDefaultInputDevice() throws -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        guard status == noErr else {
            throw CoreAudioError.apiError(status)
        }

        guard deviceID != kAudioObjectUnknown else {
            throw CoreAudioError.deviceNotFound
        }

        return deviceID
    }

    /// Get all audio devices in the system
    static func getAllDevices() -> [AudioDeviceID] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize
        )

        guard status == noErr else { return [] }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceIDs
        )

        guard status == noErr else { return [] }
        return deviceIDs
    }

    /// Get device UID string for a given device ID
    static func getDeviceUID(_ deviceID: AudioDeviceID) throws -> String {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uidCFString: CFString = "" as CFString
        var propertySize = UInt32(MemoryLayout<CFString>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &uidCFString
        )

        guard status == noErr else {
            throw CoreAudioError.apiError(status)
        }

        return uidCFString as String
    }

    /// Get device name for a given device ID
    static func getDeviceName(_ deviceID: AudioDeviceID) throws -> String {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var nameCFString: CFString = "" as CFString
        var propertySize = UInt32(MemoryLayout<CFString>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &nameCFString
        )

        guard status == noErr else {
            throw CoreAudioError.apiError(status)
        }

        return nameCFString as String
    }

    /// Check if input and output device UIDs match (headset mode detection)
    static func isHeadsetMode(inputDeviceID: AudioDeviceID, outputDeviceID: AudioDeviceID) -> Bool {
        guard let inputUID = try? getDeviceUID(inputDeviceID),
              let outputUID = try? getDeviceUID(outputDeviceID) else {
            return false
        }
        return inputUID == outputUID
    }

    // MARK: - Device Format Information

    /// Get the stream format for a device
    static func getDeviceFormat(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> AudioStreamBasicDescription {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var format = AudioStreamBasicDescription()
        var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &format
        )

        guard status == noErr else {
            throw CoreAudioError.apiError(status)
        }

        return format
    }

    // MARK: - Process ID Helpers

    /// Get the current process ID
    static func getCurrentProcessID() -> pid_t {
        return getpid()
    }

    // MARK: - Device Topology Detection

    /// Detect device topology mode (headset vs speakerphone)
    /// - Returns: .headset if input/output share same UID (e.g., AirPods), .speakerphone otherwise
    static func detectTopologyMode() -> DeviceTopologyMode {
        guard let inputDeviceID = try? getDefaultInputDevice(),
              let outputDeviceID = try? getDefaultOutputDevice() else {
            return .unknown
        }

        if isHeadsetMode(inputDeviceID: inputDeviceID, outputDeviceID: outputDeviceID) {
            return .headset
        }

        // Check for Bluetooth or AirPlay output (speakerphone indicators)
        if let outputUID = try? getDeviceUID(outputDeviceID) {
            // Bluetooth and AirPlay devices typically have UIDs containing these
            if outputUID.contains("Bluetooth") || outputUID.contains("AirPlay") {
                return .speakerphone
            }
        }

        // Default to speakerphone for separate input/output devices
        return .speakerphone
    }

    // MARK: - Route Change Notification

    /// Set up listener for default device changes
    /// - Parameters:
    ///   - onChange: Callback when default input or output device changes
    /// - Returns: A token to remove the listener (call removeRouteChangeListener with this)
    static func addRouteChangeListener(
        onChange: @escaping () -> Void
    ) -> RouteChangeListenerToken? {
        let token = RouteChangeListenerToken()
        token.onChange = onChange

        // Listen for default output device changes
        var outputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let outputStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &outputAddress,
            DispatchQueue.main,
            token.listenerBlock
        )

        guard outputStatus == noErr else {
            return nil
        }

        // Listen for default input device changes
        var inputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let inputStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &inputAddress,
            DispatchQueue.main,
            token.listenerBlock
        )

        if inputStatus != noErr {
            // Remove output listener if input listener failed
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &outputAddress,
                DispatchQueue.main,
                token.listenerBlock
            )
            return nil
        }

        token.isActive = true
        return token
    }

    /// Remove a route change listener
    static func removeRouteChangeListener(_ token: RouteChangeListenerToken) {
        guard token.isActive else { return }

        var outputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &outputAddress,
            DispatchQueue.main,
            token.listenerBlock
        )

        var inputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &inputAddress,
            DispatchQueue.main,
            token.listenerBlock
        )

        token.isActive = false
    }
}

// MARK: - Device Topology Mode

enum DeviceTopologyMode {
    case headset      // Input/output share same device (e.g., AirPods)
    case speakerphone // Separate input/output (e.g., USB mic + Bluetooth speakers)
    case unknown
}

// MARK: - Route Change Listener Token

/// Token for managing route change listeners
final class RouteChangeListenerToken {
    var isActive = false
    var onChange: (() -> Void)?

    lazy var listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.onChange?()
    }
}

// MARK: - AudioStreamBasicDescription Extensions

extension AudioStreamBasicDescription {
    var description: String {
        return """
        Sample Rate: \(mSampleRate) Hz
        Format: \(formatIDString)
        Channels: \(mChannelsPerFrame)
        Bits per Channel: \(mBitsPerChannel)
        Frames per Packet: \(mFramesPerPacket)
        Bytes per Frame: \(mBytesPerFrame)
        """
    }

    private var formatIDString: String {
        let formatID = mFormatID
        let bytes = [
            UInt8((formatID >> 24) & 0xFF),
            UInt8((formatID >> 16) & 0xFF),
            UInt8((formatID >> 8) & 0xFF),
            UInt8(formatID & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "Unknown"
    }
}
