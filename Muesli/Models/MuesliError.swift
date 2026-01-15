import Foundation

/// Unified error type for the Muesli app
/// Provides user-friendly error messages and recovery suggestions
enum MuesliError: Error, LocalizedError {
    
    // MARK: - Permission Errors
    
    /// Screen recording permission was not granted
    case screenRecordingDenied
    
    /// Microphone permission was not granted
    case microphoneDenied
    
    /// Both screen recording and microphone permissions are required
    case permissionsMissing
    
    // MARK: - Model Errors
    
    /// No transcription model is downloaded or selected
    case modelNotFound
    
    /// The model file appears to be corrupted
    case modelCorrupted(modelName: String)
    
    /// The model failed to load
    case modelLoadFailed(underlying: Error)
    
    /// Model download failed
    case modelDownloadFailed(underlying: Error)
    
    // MARK: - Recording Errors
    
    /// A recording is already in progress
    case alreadyRecording
    
    /// No recording is currently in progress
    case notRecording
    
    /// Failed to start audio capture
    case captureStartFailed(underlying: Error)
    
    /// No audio content available to capture
    case noAudioContent
    
    /// The captured application was closed
    case capturedAppClosed(appName: String)
    
    /// Failed to create output directory
    case outputDirectoryCreationFailed
    
    // MARK: - Transcription Errors
    
    /// Transcription failed
    case transcriptionFailed(underlying: Error)
    
    /// WhisperKit is not initialized
    case whisperKitNotInitialized
    
    /// Post-processing transcription failed
    case postProcessingFailed(underlying: Error)
    
    // MARK: - File Errors
    
    /// Failed to save transcript to disk
    case transcriptSaveFailed(underlying: Error)
    
    /// Failed to save audio file
    case audioSaveFailed(underlying: Error)
    
    /// Meeting directory not found
    case meetingDirectoryNotFound
    
    // MARK: - Refinement Errors
    
    /// LLM model not available for refinement
    case llmModelNotAvailable
    
    /// Transcript refinement failed
    case refinementFailed(underlying: Error)
    
    // MARK: - LocalizedError Implementation
    
    var errorDescription: String? {
        switch self {
        case .screenRecordingDenied:
            return "Screen Recording permission is required"
        case .microphoneDenied:
            return "Microphone permission is required"
        case .permissionsMissing:
            return "Required permissions are missing"
        case .modelNotFound:
            return "No transcription model available"
        case .modelCorrupted(let modelName):
            return "Model '\(modelName)' appears to be corrupted"
        case .modelLoadFailed(let error):
            return "Failed to load model: \(error.localizedDescription)"
        case .modelDownloadFailed(let error):
            return "Failed to download model: \(error.localizedDescription)"
        case .alreadyRecording:
            return "A recording is already in progress"
        case .notRecording:
            return "No recording is currently in progress"
        case .captureStartFailed(let error):
            return "Failed to start recording: \(error.localizedDescription)"
        case .noAudioContent:
            return "No audio content available to capture"
        case .capturedAppClosed(let appName):
            return "'\(appName)' was closed"
        case .outputDirectoryCreationFailed:
            return "Failed to create output directory"
        case .transcriptionFailed(let error):
            return "Transcription failed: \(error.localizedDescription)"
        case .whisperKitNotInitialized:
            return "Transcription engine not initialized"
        case .postProcessingFailed(let error):
            return "Post-processing failed: \(error.localizedDescription)"
        case .transcriptSaveFailed(let error):
            return "Failed to save transcript: \(error.localizedDescription)"
        case .audioSaveFailed(let error):
            return "Failed to save audio: \(error.localizedDescription)"
        case .meetingDirectoryNotFound:
            return "Meeting directory not found"
        case .llmModelNotAvailable:
            return "LLM model not available for refinement"
        case .refinementFailed(let error):
            return "Transcript refinement failed: \(error.localizedDescription)"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .screenRecordingDenied:
            return "Please grant Screen Recording permission in System Settings > Privacy & Security > Screen & System Audio Recording."
        case .microphoneDenied:
            return "Please grant Microphone permission in System Settings > Privacy & Security > Microphone."
        case .permissionsMissing:
            return "Please grant the required permissions in System Settings."
        case .modelNotFound:
            return "Please download a transcription model in Preferences > Transcription Models."
        case .modelCorrupted:
            return "Try deleting and re-downloading the model."
        case .modelLoadFailed:
            return "Try restarting the app or re-downloading the model."
        case .modelDownloadFailed:
            return "Check your internet connection and try again."
        case .alreadyRecording:
            return "Stop the current recording before starting a new one."
        case .notRecording:
            return nil
        case .captureStartFailed:
            return "Ensure Screen Recording permission is granted and the target app is running."
        case .noAudioContent:
            return "Make sure the meeting app is running and has audio playing."
        case .capturedAppClosed:
            return "The recording was saved. You can resume recording or start a new one."
        case .outputDirectoryCreationFailed:
            return "Check that you have write permission to the output directory."
        case .transcriptionFailed, .whisperKitNotInitialized, .postProcessingFailed:
            return "Try re-transcribing from the completed recording."
        case .transcriptSaveFailed, .audioSaveFailed:
            return "Check disk space and permissions for the output directory."
        case .meetingDirectoryNotFound:
            return "The meeting may have been deleted or moved."
        case .llmModelNotAvailable:
            return "Download an LLM model in Preferences to enable transcript refinement."
        case .refinementFailed:
            return "Try refining the transcript again later."
        }
    }
    
    var failureReason: String? {
        switch self {
        case .screenRecordingDenied, .microphoneDenied, .permissionsMissing:
            return "The app doesn't have the required permissions."
        case .modelNotFound, .modelCorrupted, .modelLoadFailed, .modelDownloadFailed:
            return "There was a problem with the transcription model."
        case .alreadyRecording, .notRecording:
            return nil
        case .captureStartFailed, .noAudioContent, .capturedAppClosed:
            return "There was a problem with audio capture."
        case .outputDirectoryCreationFailed:
            return "There was a problem with the file system."
        case .transcriptionFailed, .whisperKitNotInitialized, .postProcessingFailed:
            return "There was a problem with transcription."
        case .transcriptSaveFailed, .audioSaveFailed, .meetingDirectoryNotFound:
            return "There was a problem saving files."
        case .llmModelNotAvailable, .refinementFailed:
            return "There was a problem with transcript refinement."
        }
    }
}

// MARK: - Recording Error Wrapper

/// Contextual recording error that wraps MuesliError with additional metadata
struct RecordingError: Error, LocalizedError {
    let underlying: MuesliError
    let context: Context
    let timestamp: Date
    let sessionID: UUID?
    
    enum Context {
        case starting(app: String?)
        case recording(duration: TimeInterval)
        case stopping
        case saving(directory: URL)
        case transcribing(modelName: String)
    }
    
    init(underlying: MuesliError, context: Context, sessionID: UUID? = nil) {
        self.underlying = underlying
        self.context = context
        self.timestamp = Date()
        self.sessionID = sessionID
    }
    
    var errorDescription: String? {
        switch context {
        case .starting(let app):
            if let app = app {
                return "Failed to start recording \(app): \(underlying.localizedDescription)"
            } else {
                return "Failed to start recording: \(underlying.localizedDescription)"
            }
        case .recording(let duration):
            return "Recording failed after \(Int(duration))s: \(underlying.localizedDescription)"
        case .stopping:
            return "Failed to stop recording: \(underlying.localizedDescription)"
        case .saving:
            return "Failed to save recording: \(underlying.localizedDescription)"
        case .transcribing(let model):
            return "Transcription failed (\(model)): \(underlying.localizedDescription)"
        }
    }
    
    var recoverySuggestion: String? {
        underlying.recoverySuggestion
    }
    
    var failureReason: String? {
        underlying.failureReason
    }
}
