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
    
    /// Duration of each transcription chunk for live recordings (seconds).
    /// Whisper was trained on 30s windows; longer chunks improve accuracy.
    /// 15s balances context quality with ~2-3s processing latency on M3.
    static let transcriptionChunkDuration: TimeInterval = 15.0
    
    /// Overlap between transcription chunks for continuity (seconds)
    static let transcriptionOverlapDuration: TimeInterval = 3.0
    
    /// Duration of warmup chunks at the start of a recording (seconds).
    /// Shorter than steady-state to get initial text on screen quickly.
    static let warmupChunkDuration: TimeInterval = 3.0
    
    /// Number of warmup chunks per speaker before switching to full duration
    static let warmupChunkCount: Int = 1
    
    /// Overlap for warmup chunks (seconds)
    static let warmupOverlapDuration: TimeInterval = 1.0
    
    /// Post-processing chunk duration (30 seconds - Whisper's optimal training window)
    static let postProcessingChunkDuration: TimeInterval = 30.0
    
    /// Post-processing overlap (5 seconds - prevents word cutoffs at boundaries)
    static let postProcessingOverlapDuration: TimeInterval = 5.0
    
    /// Skip second-pass for very short recordings where overhead outweighs gains
    static let secondPassMinDurationSeconds: TimeInterval = 30.0
    
    /// Minimum samples needed before processing (chunk duration at whisper sample rate)
    static var minSamplesForProcessing: Int {
        whisperSampleRate * Int(transcriptionChunkDuration)
    }
    
    /// Overlap samples between chunks
    static var overlapSamples: Int {
        Int(Double(whisperSampleRate) * transcriptionOverlapDuration)
    }
    
    /// Minimum samples for warmup chunks
    static var warmupMinSamples: Int {
        whisperSampleRate * Int(warmupChunkDuration)
    }
    
    /// Overlap samples for warmup chunks
    static var warmupOverlapSamples: Int {
        whisperSampleRate * Int(warmupOverlapDuration)
    }
    
    // MARK: - Buffer Management
    
    /// Maximum time to buffer audio while model loads (seconds)
    /// This is a generous timeout (5 minutes) to cover even the largest models
    /// on the slowest supported hardware. Memory is bounded by maxBufferSamples,
    /// not this timeout - we use a rolling 30s buffer regardless of how long
    /// we wait. This timeout is just a safety net for genuinely broken situations.
    static let bufferTimeoutSeconds: TimeInterval = 300.0
    
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

    /// Minimum sample count for strict VAD mode (1 second at 16kHz)
    static let strictMinimumSamples: Int = 16_000

    /// Minimum sample count for boundary VAD mode (0.5 seconds at 16kHz)
    static let boundaryMinimumSamples: Int = 8_000

    /// RMS threshold for boundary VAD fallback mode
    static let boundaryVadThreshold: Float = 0.005

    /// Required significant-energy ratio for strict VAD mode
    static let strictSignificantRatio: Float = 0.1

    /// Required significant-energy ratio for boundary VAD fallback mode
    static let boundarySignificantRatio: Float = 0.05

    /// Maximum tail retained after a failed boundary silence flush (5 seconds)
    static let boundaryRetainedTailSamples: Int = 80_000

    /// Hard cap for boundary retention window (30 seconds)
    static let boundaryMaxRetentionSamples: Int = 480_000

    /// Maximum non-progress retries for the same boundary window before forced eviction
    static let boundaryMaxRetryCountPerWindow: Int = 2

    /// Minimum samples to force-evict when retry cap is exceeded
    static let boundaryMinAdvanceSamples: Int = 8_000

    /// Feature toggle for strict->boundary fallback in live stabilizer mode
    static let enableLiveBoundaryFallback: Bool = true
    
    // MARK: - Live Stabilizer
    
    /// Consecutive matching hypotheses required before commit
    static let stabilizerAgreementWindow: Int = 2
    
    /// Timing slack for overlap boundary calculations
    static let stabilizerJitterMs: Int = 250
    
    /// Similarity threshold for overlap matching
    static let stabilizerSimilarityThreshold: Double = 0.70
    
    /// Maximum number of tokens retained for draft tail
    static let stabilizerMaxDraftTokens: Int = 40
    
    /// Maximum draft UI emit frequency (4Hz)
    static let stabilizerDraftEmitIntervalMs: Int = 250
    
    /// Seconds of silence after last voice activity before flushing pending stabilizer hypotheses.
    /// Keeps live output responsive when the speaker pauses or stops.
    static let silenceFlushDelay: TimeInterval = 3.0
    
    // MARK: - Audio Level Updates
    
    /// Minimum interval between audio level UI updates (~30fps)
    static let levelUpdateInterval: TimeInterval = 0.033
    
    // MARK: - Error Recovery
    
    /// Maximum consecutive audio errors before stopping recording
    static let maxConsecutiveAudioErrors: Int = 100
    
    /// Maximum retries for model loading
    static let maxModelRetries: Int = 3
    
    // MARK: - Echo Cancellation (AEC)
    
    /// Acoustic delay for AEC (milliseconds)
    /// This accounts for DAC + acoustic propagation + ADC latency
    /// Typical range: 15-50ms depending on audio hardware
    /// Default: 50ms (conservative for laptop speakers with room reflections)
    static let aecAcousticDelayMs: Int = 50
    
    /// AEC filter length (number of taps)
    /// At 48kHz: 1024 taps = ~21ms of echo path modeling
    /// Longer filters handle longer echo delays but require more computation
    static let aecFilterLength: Int = 1024
    
    /// AEC learning rate (NLMS step size)
    /// Higher values adapt faster but may be less stable
    /// Typical range: 0.1-0.5
    static let aecLearningRate: Float = 0.2
    
    /// AEC gap detection threshold (milliseconds).
    /// Gaps larger than this are filled with silence to maintain sample count continuity.
    /// Default: 50ms (above typical ScreenCaptureKit jitter of ~10-30ms)
    /// Reference: https://nonstrict.eu/blog/2024/handling-audio-capture-gaps-on-macos
    static let aecGapThresholdMs: Int = 50
    
    /// Maximum gap to fill with silence (milliseconds).
    /// Larger gaps are clamped and logged as warnings (may indicate stream restart).
    /// Default: 500ms = 24000 samples @ 48kHz (96KB max allocation)
    static let aecMaxGapMs: Int = 500
    
    /// Maximum number of system audio buffers to keep for AEC reference lookup.
    /// At ~20ms per buffer, 150 buffers covers ~3 seconds of audio.
    /// This accommodates clock drift between mic and system audio streams (~1-2% drift is common).
    static let maxSystemAudioBuffers: Int = 150
    
    // MARK: - AEC Debugging (Debug Builds Only)
    
    #if DEBUG
    /// Enable verbose AEC diagnostic logging
    /// When enabled, logs RMS levels, match quality, and filter state every Nth buffer
    /// WARNING: May impact real-time performance; use only for debugging
    /// Enable via: `defaults write com.muesli.app aecVerboseLogging -bool true`
    static var aecVerboseLogging: Bool {
        get { UserDefaults.standard.bool(forKey: "aecVerboseLogging") }
        set { UserDefaults.standard.set(newValue, forKey: "aecVerboseLogging") }
    }
    
    /// Log sampling interval for verbose AEC diagnostics
    /// Logs every Nth buffer to minimize performance impact (~2-3 logs/second at 10)
    static let aecLogSampleInterval: Int = 10
    
    /// Enable/disable AEC gap fill for diagnostic testing.
    /// When disabled, gaps are detected but NOT filled with silence.
    /// WARNING: Disabling causes sample count drift and may break AEC sync.
    /// DO NOT SHIP with this disabled - diagnostic use only.
    /// Enable via: `defaults write com.muesli.app aecEnableGapFill -bool false`
    static var aecEnableGapFill: Bool {
        get {
            // Default to true if not explicitly set
            if UserDefaults.standard.object(forKey: "aecEnableGapFill") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "aecEnableGapFill")
        }
        set { UserDefaults.standard.set(newValue, forKey: "aecEnableGapFill") }
    }
    #endif
}
