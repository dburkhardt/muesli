//
//  AudioCaptureServiceProtocol.swift
//  Muesli
//
//  Protocol for audio capture services.
//  Allows RecordingController to work with either AudioCaptureService (ScreenCaptureKit)
//  or TapAudioCaptureService (Core Audio taps).
//

import Foundation
import CoreMedia

// MARK: - Shared Capture Error Type

/// Shared capture error type for all audio capture services
/// This allows RecordingController to handle errors uniformly regardless of capture backend
enum AudioCaptureError: Error, LocalizedError {
    case noContentToCapture
    case streamConfigurationFailed
    case permissionDenied
    case streamStartFailed(underlying: Error)
    case alreadyRecording
    case notRecording
    case streamInterrupted(underlying: Error?)
    case bufferHandlerNotSet
    case tapCreationFailed
    case microphoneStartFailed(Error)
    case notAvailable

    var errorDescription: String? {
        switch self {
        case .noContentToCapture:
            return "No content available to capture"
        case .streamConfigurationFailed:
            return "Failed to configure audio stream"
        case .permissionDenied:
            return "Audio capture permission denied"
        case .streamStartFailed(let error):
            return "Failed to start stream: \(error.localizedDescription)"
        case .alreadyRecording:
            return "Already recording"
        case .notRecording:
            return "Not currently recording"
        case .streamInterrupted(let error):
            if let error = error {
                return "Stream interrupted: \(error.localizedDescription)"
            }
            return "Stream was interrupted"
        case .bufferHandlerNotSet:
            return "Buffer handler must be set before starting capture"
        case .tapCreationFailed:
            return "Failed to create audio tap"
        case .microphoneStartFailed(let error):
            return "Failed to start microphone: \(error.localizedDescription)"
        case .notAvailable:
            return "Audio capture not available"
        }
    }
}

// MARK: - Callback Types

/// Callback type for receiving audio buffers
typealias AudioBufferHandler = @Sendable (CMSampleBuffer, AudioStreamType) -> Void

/// Callback type for when the stream is interrupted (e.g., captured app quits)
typealias StreamInterruptedHandler = @Sendable (Error?) -> Void

/// Callback type for audio level updates (0.0 to 1.0)
typealias AudioLevelHandler = @Sendable (Float, AudioStreamType) -> Void

/// Callback type for service warnings (message, details, canRetry)
typealias AudioWarningHandler = @Sendable (String, String, Bool) -> Void

/// Protocol for audio capture services
/// Both AudioCaptureService and TapAudioCaptureService conform to this
protocol AudioCaptureServiceProtocol: Actor {
    /// Whether currently recording
    var isRecording: Bool { get }

    /// Set the microphone device to use
    func setMicrophoneDevice(_ deviceID: String?)

    /// Set callback for audio buffers
    func setBufferHandler(_ handler: @escaping AudioBufferHandler)

    /// Set callback for stream interruption
    func setInterruptedHandler(_ handler: @escaping StreamInterruptedHandler)

    /// Set callback for audio level updates
    func setLevelHandler(_ handler: @escaping AudioLevelHandler)

    /// Set callback for warnings
    func setWarningHandler(_ handler: @escaping AudioWarningHandler)

    /// Start audio capture (all system audio)
    func startCapture() async throws

    /// Start audio capture for a specific app
    func startCapture(forBundleIdentifier bundleIdentifier: String) async throws

    /// Stop audio capture
    func stopCapture() async throws
}
