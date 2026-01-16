import Foundation

/// Centralized audio configuration constants
/// Used across the transcription pipeline for consistent audio handling
enum AudioConfiguration {
    // MARK: - Sample Rates
    
    /// WhisperKit requires 16kHz mono audio for transcription
    static let whisperSampleRate: Int = 16000
    
    /// ScreenCaptureKit captures system audio at 48kHz
    static let captureSampleRate: Int = 48000
    
    /// System audio channel count (stereo)
    static let captureChannelCount: Int = 2
    
    /// Microphone sample rate (48kHz on macOS 15+)
    static let microphoneSampleRate: Int = 48000
    
    // MARK: - Transcription Timing
    
    /// Duration of each transcription chunk (seconds)
    static let transcriptionChunkDuration: TimeInterval = 5.0
    
    /// Overlap between transcription chunks for continuity (seconds)
    static let transcriptionOverlapDuration: TimeInterval = 1.5
    
    /// Minimum samples needed before processing (chunk duration at whisper sample rate)
    static var minSamplesForProcessing: Int {
        whisperSampleRate * Int(transcriptionChunkDuration)
    }
    
    /// Overlap samples between chunks
    static var overlapSamples: Int {
        whisperSampleRate * Int(transcriptionOverlapDuration)
    }
    
    // MARK: - Buffer Management
    
    /// Maximum time to buffer audio while model loads (seconds)
    static let bufferTimeoutSeconds: TimeInterval = 30.0
    
    /// Maximum buffer size in samples (30 seconds at 16kHz = 480,000 samples)
    static let maxBufferSamples: Int = 480_000
    
    // MARK: - File Output Buffer Management
    
    /// Maximum number of audio buffers to queue when writer is not ready
    /// This prevents audio gaps when AVAssetWriterInput.isReadyForMoreMediaData is false
    /// Default: 10 buffers (~200ms of audio at typical buffer sizes)
    static let maxQueuedBuffers: Int = 10
    
    // MARK: - Voice Activity Detection
    
    /// RMS threshold for voice activity detection (-40dB equivalent)
    static let vadThreshold: Float = 0.01
    
    // MARK: - Audio Level Updates
    
    /// Minimum interval between audio level UI updates (~30fps)
    static let levelUpdateInterval: TimeInterval = 0.033
    
    // MARK: - Error Recovery
    
    /// Maximum consecutive audio errors before stopping recording
    static let maxConsecutiveAudioErrors: Int = 100
    
    /// Maximum retries for model loading
    static let maxModelRetries: Int = 3
}
