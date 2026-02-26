@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import os.lock
import os.log
@preconcurrency import WhisperKit

/// Global typealias for live draft callbacks used across TranscriptionService, TranscriptionCoordinator, and RecordingController
typealias TranscriptionDraftHandler = @Sendable (String, TranscriptionService.TranscriptSegment.Speaker) -> Void

/// Service for real-time audio transcription using WhisperKit
/// Handles both system audio ("Them") and microphone audio ("Me")
final class TranscriptionService: @unchecked Sendable, TranscriptionServiceProtocol {
    // MARK: - Logging
    
    private let logger = Logger(subsystem: "com.muesli.app", category: "TranscriptionService")
    
    // MARK: - Types
    
    /// Transcription mode: live (real-time) or post-processing (after recording)
    enum TranscriptionMode: String, Sendable {
        case live
        case postProcessing
    }
    
    /// Represents a transcribed segment with speaker info
    struct TranscriptSegment: Sendable {
        let text: String
        let timestamp: TimeInterval
        let speaker: Speaker
        
        enum Speaker: String, Sendable {
            case me = "Me"
            case them = "Them"
        }
    }
    
    /// Callback for new transcript segments
    typealias TranscriptHandler = @Sendable (TranscriptSegment) -> Void
    
    /// Callback for live draft tail updates
    typealias DraftHandler = @Sendable (String, TranscriptSegment.Speaker) -> Void
    
    /// Callback for transcription warnings (message, details)
    typealias TranscriptionWarningHandler = @Sendable (String, String) -> Void

    /// Summary of stop-time buffer flush behavior.
    struct StopFlushResult: Sendable {
        let completedFullFlush: Bool
        let flushDurationMs: Int
        let remainingBufferedSamples: Int
    }
    
    /// Information about audio chunks to process
    private struct ChunkInfo {
        let systemChunk: [Float]?
        let micChunk: [Float]?
        let startTime: Date
        let systemOffset: Int
        let micOffset: Int
        /// Cumulative sample offset for system audio (for audio-timeline timestamps)
        let systemCumulativeOffset: Int
        /// Cumulative sample offset for mic audio (for audio-timeline timestamps)
        let micCumulativeOffset: Int
    }

    enum VADMode: String, Sendable {
        case strict
        case boundary
    }

    enum VADDecisionReason: String, Sendable {
        case strictPassed
        case boundaryPassed
        case droppedBelowRMS
        case droppedTooShort
        case droppedSparseEnergy
        case droppedAfterRetryCap
    }

    struct VADDecision: Sendable {
        let passed: Bool
        let mode: VADMode
        let reason: VADDecisionReason
        let rms: Float
        let significantRatio: Float
        let sampleCount: Int
    }

    private enum StreamChannel: String, Sendable {
        case system
        case mic

        var speaker: TranscriptSegment.Speaker {
            switch self {
            case .system: return .them
            case .mic: return .me
            }
        }

        var logSpeaker: String {
            switch self {
            case .system: return "them"
            case .mic: return "me"
            }
        }
    }

    private struct BoundaryDiagnostics: Sendable {
        var boundaryFallbackAttempted: Int = 0
        var boundaryFallbackSucceeded: Int = 0
        var forcedBufferEvictions: Int = 0
        var retainedTailSamples: Int = 0
        var skippedPartialStrict: Int = 0
        var skippedPartialBoundary: Int = 0
    }

    private struct BoundarySnapshot: Sendable {
        let channel: StreamChannel
        let samples: [Float]
        let cumulativeOffset: Int
        let startTime: Date
        let contextSuffix: String
        let silenceDuration: TimeInterval
        let bufferVersion: Int
        let retryCount: Int
    }

    private struct BoundaryDecision {
        let shouldTranscribe: Bool
        let reason: VADDecisionReason
        let strictDecision: VADDecision
        let boundaryDecision: VADDecision?
        let boundaryFallbackAttempted: Bool
        let boundaryFallbackSucceeded: Bool
    }

    private struct PendingTranscription {
        let samples: [Float]
        let speaker: TranscriptSegment.Speaker
        let startTime: Date
        let cumulativeOffset: Int
        let contextSuffix: String
        let source: String
    }

    typealias VADEvaluator = @Sendable ([Float], VADMode) -> VADDecision
    typealias TranscriptionExecutor = @Sendable (
        [Float],
        TranscriptSegment.Speaker,
        Date,
        Int,
        String?
    ) async -> String?
    
    // MARK: - Properties
    
    private var whisperKit: WhisperKit?
    private var isInitialized = false
    private var transcriptHandler: TranscriptHandler?
    private var draftHandler: DraftHandler?
    private var warningHandler: TranscriptionWarningHandler?
    private var liveStabilizer: LiveStabilizer?
    private var vadEvaluatorOverride: VADEvaluator?
    private var transcriptionExecutorOverride: TranscriptionExecutor?
    
    private var isLiveStabilizerEnabled: Bool {
        if UserDefaults.standard.object(forKey: AppStorageKeys.liveStabilizerEnabled) == nil {
            return false
        }
        return UserDefaults.standard.bool(forKey: AppStorageKeys.liveStabilizerEnabled)
    }

    private var shouldAttemptBoundaryFallback: Bool {
        AudioConfiguration.enableLiveBoundaryFallback &&
            transcriptionMode == .live &&
            liveStabilizer != nil
    }
    
    /// Current transcription mode
    var transcriptionMode: TranscriptionMode = .live
    
    // Audio buffers for chunked processing (protected state)
    private struct BufferState {
        var systemAudioBuffer: [Float] = []
        var micAudioBuffer: [Float] = []
        var isProcessing: Bool = false
        var recordingStartTime: Date?
        // Overlap tracking: track how many samples have been processed
        var systemProcessedSamples: Int = 0
        var micProcessedSamples: Int = 0
        // Cumulative sample counters for audio-timeline timestamps
        var systemTotalSamplesReceived: Int = 0
        var micTotalSamplesReceived: Int = 0
        // Warmup tracking: count chunks processed per speaker
        var systemChunksProcessed: Int = 0
        var micChunksProcessed: Int = 0
        // Context chaining: last transcript suffix per speaker (~200 chars)
        var systemLastTranscriptSuffix: String = ""
        var micLastTranscriptSuffix: String = ""
        // Silence flush: track when last VAD-positive chunk was processed per stream.
        // nil until first voice activity; silence flush is gated on != nil.
        var systemLastVoiceTime: Date?
        var micLastVoiceTime: Date?
        var systemSilenceFlushDone: Bool = false
        var micSilenceFlushDone: Bool = false
        var systemBufferVersion: Int = 0
        var micBufferVersion: Int = 0
        var systemBoundaryRetryCount: Int = 0
        var micBoundaryRetryCount: Int = 0
        var systemBoundaryCooldownVersion: Int?
        var micBoundaryCooldownVersion: Int?
        var systemBoundaryFlushInFlight: Bool = false
        var micBoundaryFlushInFlight: Bool = false
        var systemBoundaryDiagnostics: BoundaryDiagnostics = .init()
        var micBoundaryDiagnostics: BoundaryDiagnostics = .init()
    }
    private let bufferState = OSAllocatedUnfairLock(initialState: BufferState())
    
    // Processing state
    private var processingTask: Task<Void, Never>?
    
    // Configuration (using centralized AudioConfiguration)
    private let chunkDuration: TimeInterval
    private let sampleRate: Int = AudioConfiguration.whisperSampleRate
    private let minSamplesForProcessing: Int  // Minimum samples before processing
    private let overlapSamples: Int  // Samples to overlap between chunks
    
    // Warmup configuration: warmup is skipped when user chunk <= warmup duration
    private let warmupMinSamples: Int
    private let warmupOverlapSamples: Int
    private let warmupChunkCount: Int
    
    // VAD configuration
    private let vadThreshold: Float = AudioConfiguration.vadThreshold
    
    // MARK: - Initialization
    
    /// Initialize transcription service with optional chunk duration
    /// - Parameter chunkDuration: Duration of each transcription chunk (2-30 seconds), defaults to 15.0
    init(chunkDuration: TimeInterval = AudioConfiguration.transcriptionChunkDuration) {
        // Clamp chunk duration to valid range
        self.chunkDuration = min(max(chunkDuration, 2.0), 30.0)
        
        // Calculate samples based on chunk duration
        minSamplesForProcessing = sampleRate * Int(self.chunkDuration)
        
        // Calculate overlap: maintain ~20% ratio, using lround to avoid Int truncation
        // that would yield zero overlap for short durations (e.g. 3s * 0.2 = 0.6 → Int = 0)
        let overlapRatio = AudioConfiguration.transcriptionOverlapDuration /
            AudioConfiguration.transcriptionChunkDuration
        let overlapDuration = self.chunkDuration * overlapRatio
        overlapSamples = Int(lround(overlapDuration)) * sampleRate
        
        // Skip warmup when user-configured chunk is already at or below warmup duration
        if self.chunkDuration <= AudioConfiguration.warmupChunkDuration {
            warmupMinSamples = minSamplesForProcessing
            warmupOverlapSamples = overlapSamples
            warmupChunkCount = 0
        } else {
            warmupMinSamples = AudioConfiguration.warmupMinSamples
            warmupOverlapSamples = AudioConfiguration.warmupOverlapSamples
            warmupChunkCount = AudioConfiguration.warmupChunkCount
        }
    }
    
    // MARK: - Setup
    
    /// Initialize WhisperKit with the specified model path
    /// - Parameter modelPath: Path to the WhisperKit model directory (required)
    func initialize(modelPath: URL) async throws {
        guard !isInitialized else { return }
        
        // Use Application Support for all WhisperKit storage to avoid Documents folder prompts
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let muesliDir = appSupport.appendingPathComponent("Muesli", isDirectory: true)
        
        // Create config with explicit downloadBase and tokenizerFolder in Application Support
        // This prevents WhisperKit/Hub from defaulting to ~/Documents/huggingface
        let config = WhisperKitConfig(
            downloadBase: muesliDir,
            modelFolder: modelPath.path,
            tokenizerFolder: muesliDir.appendingPathComponent("Tokenizers"),
            verbose: false,
            download: false  // Don't download since we're using a local model
        )
        
        // Initialize WhisperKit with optimized configuration for Apple Silicon
        whisperKit = try await WhisperKit(config)
        isInitialized = true
    }
    
    /// Set transcription mode (live or post-processing)
    func setTranscriptionMode(_ mode: TranscriptionMode) {
        transcriptionMode = mode
    }
    
    /// Set the handler for new transcript segments
    func setTranscriptHandler(_ handler: @escaping TranscriptHandler) {
        transcriptHandler = handler
    }
    
    /// Set the handler for live draft text updates
    func setDraftHandler(_ handler: @escaping TranscriptionDraftHandler) {
        draftHandler = handler
    }
    
    /// Set the handler for transcription warnings
    func setWarningHandler(_ handler: @escaping TranscriptionWarningHandler) {
        warningHandler = handler
    }
    
    // MARK: - Recording Control
    
    /// Start transcription processing
    func startTranscription(recordingStartTime: Date) {
        if transcriptionMode == .live && isLiveStabilizerEnabled {
            liveStabilizer = LiveStabilizer()
        } else {
            liveStabilizer = nil
        }

        bufferState.withLock { state in
            state.recordingStartTime = recordingStartTime
            state.systemAudioBuffer.removeAll()
            state.micAudioBuffer.removeAll()
            state.systemProcessedSamples = 0
            state.micProcessedSamples = 0
            state.systemTotalSamplesReceived = 0
            state.micTotalSamplesReceived = 0
            state.systemChunksProcessed = 0
            state.micChunksProcessed = 0
            state.systemLastTranscriptSuffix = ""
            state.micLastTranscriptSuffix = ""
            state.systemLastVoiceTime = nil
            state.micLastVoiceTime = nil
            state.systemSilenceFlushDone = false
            state.micSilenceFlushDone = false
            state.systemBufferVersion = 0
            state.micBufferVersion = 0
            state.systemBoundaryRetryCount = 0
            state.micBoundaryRetryCount = 0
            state.systemBoundaryCooldownVersion = nil
            state.micBoundaryCooldownVersion = nil
            state.systemBoundaryFlushInFlight = false
            state.micBoundaryFlushInFlight = false
            state.systemBoundaryDiagnostics = .init()
            state.micBoundaryDiagnostics = .init()
            state.isProcessing = true
        }
        
        // Start background processing loop only for live mode
        if transcriptionMode == .live {
            startProcessingLoop()
        }
    }
    
    /// Stop transcription processing.
    /// - Parameters:
    ///   - maxFlushDuration: Optional maximum wait for final buffer flush. `nil` waits for full completion.
    ///   - allowDeferredFlush: If true, flush can continue in background after the timeout is reached.
    @discardableResult
    func stopTranscription(
        maxFlushDuration: TimeInterval? = nil,
        allowDeferredFlush: Bool = false
    ) async -> StopFlushResult {
        // Signal the processing loop to stop (it checks isProcessing each iteration)
        bufferState.withLock { state in
            state.isProcessing = false
        }
        
        // Wait for the processing task to complete gracefully instead of cancelling
        // This allows any in-flight WhisperKit transcription to finish
        if let task = processingTask {
            await task.value  // Wait for task to complete instead of cancelling
        }
        processingTask = nil

        let flushStart = Date()
        let didCompleteFlush: Bool
        if let maxFlushDuration, maxFlushDuration > 0 {
            let flushTask = Task { [weak self] in
                await self?.performFinalFlush()
            }
            let completedWithinBudget = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await flushTask.value
                    return true
                }
                group.addTask {
                    try? await Task.sleep(
                        nanoseconds: UInt64(maxFlushDuration * 1_000_000_000)
                    )
                    return false
                }
                let first = await group.next() ?? true
                group.cancelAll()
                return first
            }

            if completedWithinBudget {
                didCompleteFlush = true
            } else if allowDeferredFlush {
                didCompleteFlush = false
                let remaining = currentBufferedSampleCount()
                Task {
                    await DiagnosticLogger.shared.log(
                        .transcription,
                        "STOP_FLUSH_DEFERRED: budgetMs=\(Int(maxFlushDuration * 1000)), remainingSamples=\(remaining)"
                    )
                }
                Task.detached(priority: .utility) {
                    await flushTask.value
                }
            } else {
                await flushTask.value
                didCompleteFlush = true
            }
        } else {
            await performFinalFlush()
            didCompleteFlush = true
        }

        let durationMs = Int(Date().timeIntervalSince(flushStart) * 1000)
        return StopFlushResult(
            completedFullFlush: didCompleteFlush,
            flushDurationMs: durationMs,
            remainingBufferedSamples: currentBufferedSampleCount()
        )
    }
    
    // MARK: - Audio Input
    
    /// Append audio samples from system audio (meeting participants)
    /// - Parameter samples: Float32 audio samples at 16kHz mono
    func appendSystemAudio(_ samples: [Float]) {
        bufferState.withLock { state in
            guard state.isProcessing else { return }
            state.systemAudioBuffer.append(contentsOf: samples)
            state.systemTotalSamplesReceived += samples.count
            state.systemBufferVersion += 1
        }
    }
    
    /// Append audio samples from microphone (user's voice)
    /// - Parameter samples: Float32 audio samples at 16kHz mono
    func appendMicrophoneAudio(_ samples: [Float]) {
        bufferState.withLock { state in
            guard state.isProcessing else { return }
            state.micAudioBuffer.append(contentsOf: samples)
            state.micTotalSamplesReceived += samples.count
            state.micBufferVersion += 1
        }
    }
    
    // MARK: - Processing
    
    private func startProcessingLoop() {
        processingTask = Task.detached { [weak self] in
            while true {
                guard let self = self else { break }
                let isStillProcessing = self.bufferState.withLock { $0.isProcessing }
                guard isStillProcessing else { break }
                
                await self.processBuffers()
                try? await Task.sleep(nanoseconds: 200_000_000)  // Check every 0.2s for faster first-token latency
            }
        }
    }
    
    private func processBuffers() async {
        // Skip processing if in post-processing mode
        guard transcriptionMode == .live else { return }
        guard isInitialized || transcriptionExecutorOverride != nil else { return }
        guard transcriptionExecutorOverride != nil || whisperKit != nil else { return }

        // Get chunks to process with overlap, using dynamic thresholds for warmup
        let chunkInfo: ChunkInfo = bufferState.withLock { state -> ChunkInfo in
            var sysChunk: [Float]?
            var micChunk: [Float]?
            let time = state.recordingStartTime ?? Date()
            var sysOffset = 0
            var micOffset = 0
            var sysCumulativeOffset = 0
            var micCumulativeOffset = 0

            // Dynamic thresholds: use smaller chunks during warmup for faster initial output
            let sysWarmup = state.systemChunksProcessed < warmupChunkCount
            let sysMinSamples = sysWarmup ? warmupMinSamples : minSamplesForProcessing
            let sysOverlap = sysWarmup ? warmupOverlapSamples : overlapSamples

            // Extract system audio chunk with overlap
            if state.systemAudioBuffer.count >= sysMinSamples {
                let startIndex = state.systemProcessedSamples > 0 ?
                    max(0, state.systemProcessedSamples - sysOverlap) : 0
                let endIndex = startIndex + sysMinSamples

                if endIndex <= state.systemAudioBuffer.count {
                    sysChunk = Array(state.systemAudioBuffer[startIndex..<endIndex])
                    sysOffset = startIndex
                    sysCumulativeOffset = state.systemTotalSamplesReceived - state.systemAudioBuffer.count + startIndex
                    // Keep overlap for next chunk; use the NEXT chunk's overlap size.
                    // Don't increment chunksProcessed here — wait until after VAD confirms
                    // voice activity so silent chunks don't consume warmup.
                    let nextOverlap = (state.systemChunksProcessed + 1) < warmupChunkCount
                        ? warmupOverlapSamples : overlapSamples
                    let samplesToRemove = endIndex - nextOverlap
                    if samplesToRemove > 0 {
                        state.systemAudioBuffer.removeFirst(samplesToRemove)
                        state.systemProcessedSamples = nextOverlap
                    } else {
                        state.systemAudioBuffer.removeFirst(endIndex)
                        state.systemProcessedSamples = 0
                    }
                    state.systemBufferVersion += 1
                }
            }

            // Dynamic thresholds for mic
            let micWarmup = state.micChunksProcessed < warmupChunkCount
            let micMinSamples = micWarmup ? warmupMinSamples : minSamplesForProcessing
            let micOverlap = micWarmup ? warmupOverlapSamples : overlapSamples

            // Extract mic audio chunk with overlap
            if state.micAudioBuffer.count >= micMinSamples {
                let startIndex = state.micProcessedSamples > 0 ? max(0, state.micProcessedSamples - micOverlap) : 0
                let endIndex = startIndex + micMinSamples

                if endIndex <= state.micAudioBuffer.count {
                    micChunk = Array(state.micAudioBuffer[startIndex..<endIndex])
                    micOffset = startIndex
                    micCumulativeOffset = state.micTotalSamplesReceived - state.micAudioBuffer.count + startIndex
                    let nextOverlap = (state.micChunksProcessed + 1) < warmupChunkCount
                        ? warmupOverlapSamples : overlapSamples
                    let samplesToRemove = endIndex - nextOverlap
                    if samplesToRemove > 0 {
                        state.micAudioBuffer.removeFirst(samplesToRemove)
                        state.micProcessedSamples = nextOverlap
                    } else {
                        state.micAudioBuffer.removeFirst(endIndex)
                        state.micProcessedSamples = 0
                    }
                    state.micBufferVersion += 1
                }
            }

            return ChunkInfo(
                systemChunk: sysChunk,
                micChunk: micChunk,
                startTime: time,
                systemOffset: sysOffset,
                micOffset: micOffset,
                systemCumulativeOffset: sysCumulativeOffset,
                micCumulativeOffset: micCumulativeOffset
            )
        }

        // Read context for chaining before transcription
        let systemContext = bufferState.withLock { $0.systemLastTranscriptSuffix }
        let micContext = bufferState.withLock { $0.micLastTranscriptSuffix }

        // Process system audio ("Them") with strict VAD check.
        // Warmup counter is advanced here (not in the lock) so silent chunks don't consume warmup.
        if let chunk = chunkInfo.systemChunk {
            let decision = evaluateVoiceActivity(chunk, mode: .strict)
            if decision.passed {
                bufferState.withLock {
                    $0.systemChunksProcessed += 1
                    $0.systemLastVoiceTime = Date()
                    $0.systemSilenceFlushDone = false
                }
                Task { await DiagnosticLogger.shared.log(.transcription,
                    "Live chunk: speaker=them, samples=\(chunk.count), reason=\(decision.reason.rawValue)") }
                if let resultText = await executeTranscription(
                    chunk,
                    speaker: .them,
                    whisperKit: whisperKit,
                    startTime: chunkInfo.startTime,
                    cumulativeSampleOffset: chunkInfo.systemCumulativeOffset,
                    previousText: systemContext.isEmpty ? nil : systemContext
                ) {
                    bufferState.withLock { $0.systemLastTranscriptSuffix = String(resultText.suffix(200)) }
                }
            }
        }

        // Process mic audio ("Me") with strict VAD check
        if let chunk = chunkInfo.micChunk {
            let decision = evaluateVoiceActivity(chunk, mode: .strict)
            if decision.passed {
                bufferState.withLock {
                    $0.micChunksProcessed += 1
                    $0.micLastVoiceTime = Date()
                    $0.micSilenceFlushDone = false
                }
                Task { await DiagnosticLogger.shared.log(.transcription,
                    "Live chunk: speaker=me, samples=\(chunk.count), reason=\(decision.reason.rawValue)") }
                if let resultText = await executeTranscription(
                    chunk,
                    speaker: .me,
                    whisperKit: whisperKit,
                    startTime: chunkInfo.startTime,
                    cumulativeSampleOffset: chunkInfo.micCumulativeOffset,
                    previousText: micContext.isEmpty ? nil : micContext
                ) {
                    bufferState.withLock { $0.micLastTranscriptSuffix = String(resultText.suffix(200)) }
                }
            }
        }

        // MARK: Silence flush — commit pending stabilizer hypotheses after silence
        await performSilenceFlushIfNeeded(whisperKit: whisperKit)
    }

    /// When a stream has had voice activity but then goes silent for `silenceFlushDelay`,
    /// evaluate strict VAD first, then optional boundary fallback before committing.
    private func performSilenceFlushIfNeeded(whisperKit: WhisperKit?, now: Date = Date()) async {
        guard let stabilizer = liveStabilizer else { return }

        let silenceDelay = AudioConfiguration.silenceFlushDelay
        let snapshots: [BoundarySnapshot] = bufferState.withLock { state in
            let startTime = state.recordingStartTime ?? now
            var pending: [BoundarySnapshot] = []

            if let lastVoice = state.systemLastVoiceTime,
               !state.systemSilenceFlushDone,
               state.systemChunksProcessed > 0,
               now.timeIntervalSince(lastVoice) > silenceDelay,
               !state.systemAudioBuffer.isEmpty,
               !state.systemBoundaryFlushInFlight,
               state.systemBoundaryCooldownVersion != state.systemBufferVersion {
                pending.append(
                    BoundarySnapshot(
                        channel: .system,
                        samples: state.systemAudioBuffer,
                        cumulativeOffset: state.systemTotalSamplesReceived - state.systemAudioBuffer.count,
                        startTime: startTime,
                        contextSuffix: state.systemLastTranscriptSuffix,
                        silenceDuration: now.timeIntervalSince(lastVoice),
                        bufferVersion: state.systemBufferVersion,
                        retryCount: state.systemBoundaryRetryCount
                    )
                )
                state.systemBoundaryFlushInFlight = true
            }

            if let lastVoice = state.micLastVoiceTime,
               !state.micSilenceFlushDone,
               state.micChunksProcessed > 0,
               now.timeIntervalSince(lastVoice) > silenceDelay,
               !state.micAudioBuffer.isEmpty,
               !state.micBoundaryFlushInFlight,
               state.micBoundaryCooldownVersion != state.micBufferVersion {
                pending.append(
                    BoundarySnapshot(
                        channel: .mic,
                        samples: state.micAudioBuffer,
                        cumulativeOffset: state.micTotalSamplesReceived - state.micAudioBuffer.count,
                        startTime: startTime,
                        contextSuffix: state.micLastTranscriptSuffix,
                        silenceDuration: now.timeIntervalSince(lastVoice),
                        bufferVersion: state.micBufferVersion,
                        retryCount: state.micBoundaryRetryCount
                    )
                )
                state.micBoundaryFlushInFlight = true
            }

            return pending
        }

        guard !snapshots.isEmpty else { return }

        var transcriptions: [PendingTranscription] = []
        for snapshot in snapshots {
            let decision = makeBoundaryDecision(
                for: snapshot.samples,
                allowFallback: shouldAttemptBoundaryFallback,
                retryCount: snapshot.retryCount
            )
            if let committed = commitBoundaryDecision(
                snapshot: snapshot,
                decision: decision,
                source: "silenceFlush",
                isFinalization: false
            ) {
                transcriptions.append(committed)
            }

            Task { await DiagnosticLogger.shared.log(.transcription,
                "Silence flush decision: speaker=\(snapshot.channel.logSpeaker), " +
                "samples=\(snapshot.samples.count), reason=\(decision.reason.rawValue), " +
                "strict=\(decision.strictDecision.reason.rawValue), " +
                "boundary=\(decision.boundaryDecision?.reason.rawValue ?? "notAttempted"), " +
                "silenceDuration=\(String(format: "%.2f", snapshot.silenceDuration))") }
        }

        for pending in transcriptions {
            if let resultText = await executeTranscription(
                pending.samples,
                speaker: pending.speaker,
                whisperKit: whisperKit,
                startTime: pending.startTime,
                cumulativeSampleOffset: pending.cumulativeOffset,
                previousText: pending.contextSuffix.isEmpty ? nil : pending.contextSuffix
            ) {
                bufferState.withLock { state in
                    if pending.speaker == .them {
                        state.systemLastTranscriptSuffix = String(resultText.suffix(200))
                    } else {
                        state.micLastTranscriptSuffix = String(resultText.suffix(200))
                    }
                }
            }
        }

        // Flush stabilizer: commit all pending hypotheses regardless of agreement window
        let output = await stabilizer.flushAll()
        for segment in output.committedSegments {
            transcriptHandler?(segment)
        }
        if let draft = output.draftUpdate {
            draftHandler?(draft.text, draft.speaker)
        }
    }

    private func processRemainingAudio() async {
        guard isInitialized || transcriptionExecutorOverride != nil else { return }

        let now = Date()
        let snapshots: [BoundarySnapshot] = bufferState.withLock { state in
            let startTime = state.recordingStartTime ?? now
            var pending: [BoundarySnapshot] = []

            if !state.systemAudioBuffer.isEmpty {
                pending.append(
                    BoundarySnapshot(
                        channel: .system,
                        samples: state.systemAudioBuffer,
                        cumulativeOffset: state.systemTotalSamplesReceived - state.systemAudioBuffer.count,
                        startTime: startTime,
                        contextSuffix: state.systemLastTranscriptSuffix,
                        silenceDuration: 0,
                        bufferVersion: state.systemBufferVersion,
                        retryCount: state.systemBoundaryRetryCount
                    )
                )
                state.systemBoundaryFlushInFlight = true
            }

            if !state.micAudioBuffer.isEmpty {
                pending.append(
                    BoundarySnapshot(
                        channel: .mic,
                        samples: state.micAudioBuffer,
                        cumulativeOffset: state.micTotalSamplesReceived - state.micAudioBuffer.count,
                        startTime: startTime,
                        contextSuffix: state.micLastTranscriptSuffix,
                        silenceDuration: 0,
                        bufferVersion: state.micBufferVersion,
                        retryCount: state.micBoundaryRetryCount
                    )
                )
                state.micBoundaryFlushInFlight = true
            }

            return pending
        }

        guard !snapshots.isEmpty else { return }
        let whisper = whisperKit

        var transcriptions: [PendingTranscription] = []
        for snapshot in snapshots {
            let decision = makeBoundaryDecision(
                for: snapshot.samples,
                allowFallback: shouldAttemptBoundaryFallback,
                retryCount: snapshot.retryCount
            )
            if let committed = commitBoundaryDecision(
                snapshot: snapshot,
                decision: decision,
                source: "finalization",
                isFinalization: true
            ) {
                transcriptions.append(committed)
            }

            logger.info(
                "Finalization decision: speaker=\(snapshot.channel.logSpeaker), samples=\(snapshot.samples.count), reason=\(decision.reason.rawValue), strict=\(decision.strictDecision.reason.rawValue), boundary=\(decision.boundaryDecision?.reason.rawValue ?? "notAttempted")"
            )
        }

        for pending in transcriptions {
            if let resultText = await executeTranscription(
                pending.samples,
                speaker: pending.speaker,
                whisperKit: whisper,
                startTime: pending.startTime,
                cumulativeSampleOffset: pending.cumulativeOffset,
                previousText: pending.contextSuffix.isEmpty ? nil : pending.contextSuffix
            ) {
                bufferState.withLock { state in
                    if pending.speaker == .them {
                        state.systemLastTranscriptSuffix = String(resultText.suffix(200))
                    } else {
                        state.micLastTranscriptSuffix = String(resultText.suffix(200))
                    }
                }
            }
        }
    }

    private func currentBufferedSampleCount() -> Int {
        bufferState.withLock { state in
            state.systemAudioBuffer.count + state.micAudioBuffer.count
        }
    }

    private func performFinalFlush() async {
        await processRemainingAudio()
        logBoundaryDiagnosticsSummary()

        if let stabilizer = liveStabilizer {
            let output = await stabilizer.flushAll()
            for segment in output.committedSegments {
                transcriptHandler?(segment)
            }
            if let draft = output.draftUpdate {
                draftHandler?(draft.text, draft.speaker)
            }
        }
        liveStabilizer = nil
    }

    private func makeBoundaryDecision(
        for samples: [Float],
        allowFallback: Bool,
        retryCount: Int
    ) -> BoundaryDecision {
        let strictDecision = evaluateVoiceActivity(samples, mode: .strict)
        if strictDecision.passed {
            return BoundaryDecision(
                shouldTranscribe: true,
                reason: .strictPassed,
                strictDecision: strictDecision,
                boundaryDecision: nil,
                boundaryFallbackAttempted: false,
                boundaryFallbackSucceeded: false
            )
        }

        var boundaryDecision: VADDecision?
        var fallbackAttempted = false
        var fallbackSucceeded = false
        var finalReason = strictDecision.reason
        if allowFallback && samples.count >= AudioConfiguration.boundaryMinimumSamples {
            fallbackAttempted = true
            let boundary = evaluateVoiceActivity(samples, mode: .boundary)
            boundaryDecision = boundary
            if boundary.passed {
                fallbackSucceeded = true
                finalReason = .boundaryPassed
            } else {
                finalReason = boundary.reason
            }
        }

        if !fallbackSucceeded && retryCount >= AudioConfiguration.boundaryMaxRetryCountPerWindow {
            finalReason = .droppedAfterRetryCap
        }

        return BoundaryDecision(
            shouldTranscribe: fallbackSucceeded,
            reason: finalReason,
            strictDecision: strictDecision,
            boundaryDecision: boundaryDecision,
            boundaryFallbackAttempted: fallbackAttempted,
            boundaryFallbackSucceeded: fallbackSucceeded
        )
    }

    private func commitBoundaryDecision(
        snapshot: BoundarySnapshot,
        decision: BoundaryDecision,
        source: String,
        isFinalization: Bool
    ) -> PendingTranscription? {
        bufferState.withLock { state in
            switch snapshot.channel {
            case .system:
                return commitBoundaryDecisionSystem(
                    state: &state,
                    snapshot: snapshot,
                    decision: decision,
                    source: source,
                    isFinalization: isFinalization
                )
            case .mic:
                return commitBoundaryDecisionMic(
                    state: &state,
                    snapshot: snapshot,
                    decision: decision,
                    source: source,
                    isFinalization: isFinalization
                )
            }
        }
    }

    private func commitBoundaryDecisionSystem(
        state: inout BufferState,
        snapshot: BoundarySnapshot,
        decision: BoundaryDecision,
        source: String,
        isFinalization: Bool
    ) -> PendingTranscription? {
        guard state.systemBoundaryFlushInFlight else { return nil }
        guard snapshot.bufferVersion == state.systemBufferVersion else {
            state.systemBoundaryFlushInFlight = false
            return nil
        }

        state.systemBoundaryDiagnostics.boundaryFallbackAttempted += decision.boundaryFallbackAttempted ? 1 : 0
        state.systemBoundaryDiagnostics.boundaryFallbackSucceeded += decision.boundaryFallbackSucceeded ? 1 : 0
        state.systemBoundaryDiagnostics.skippedPartialStrict += decision.strictDecision.passed ? 0 : 1
        state.systemBoundaryDiagnostics.skippedPartialBoundary += decision.boundaryFallbackAttempted &&
            !decision.boundaryFallbackSucceeded ? 1 : 0

        if decision.shouldTranscribe {
            let consumeCount = min(snapshot.samples.count, state.systemAudioBuffer.count)
            if consumeCount > 0 {
                state.systemAudioBuffer.removeFirst(consumeCount)
                state.systemBufferVersion += 1
            }
            state.systemProcessedSamples = 0
            state.systemChunksProcessed = 0
            state.systemSilenceFlushDone = true
            state.systemBoundaryRetryCount = 0
            state.systemBoundaryCooldownVersion = nil
            state.systemBoundaryFlushInFlight = false
            state.systemBoundaryDiagnostics.retainedTailSamples = state.systemAudioBuffer.count
            return PendingTranscription(
                samples: snapshot.samples,
                speaker: .them,
                startTime: snapshot.startTime,
                cumulativeOffset: snapshot.cumulativeOffset,
                contextSuffix: snapshot.contextSuffix,
                source: source
            )
        }

        if isFinalization {
            let consumeCount = min(snapshot.samples.count, state.systemAudioBuffer.count)
            if consumeCount > 0 {
                state.systemAudioBuffer.removeFirst(consumeCount)
                state.systemBufferVersion += 1
            }
            state.systemProcessedSamples = 0
            state.systemChunksProcessed = 0
            state.systemSilenceFlushDone = true
            state.systemBoundaryRetryCount = 0
            state.systemBoundaryCooldownVersion = nil
            state.systemBoundaryFlushInFlight = false
            state.systemBoundaryDiagnostics.retainedTailSamples = state.systemAudioBuffer.count
            return nil
        }

        var mutated = false
        let nextRetry = state.systemBoundaryRetryCount + 1
        if nextRetry > AudioConfiguration.boundaryMaxRetryCountPerWindow {
            let evict = min(AudioConfiguration.boundaryMinAdvanceSamples, state.systemAudioBuffer.count)
            if evict > 0 {
                state.systemAudioBuffer.removeFirst(evict)
                mutated = true
                state.systemBoundaryDiagnostics.forcedBufferEvictions += 1
            }
            state.systemBoundaryRetryCount = 0
        } else {
            state.systemBoundaryRetryCount = nextRetry
        }

        if state.systemAudioBuffer.count > AudioConfiguration.boundaryMaxRetentionSamples {
            let overflow = state.systemAudioBuffer.count - AudioConfiguration.boundaryMaxRetentionSamples
            state.systemAudioBuffer.removeFirst(overflow)
            mutated = true
            state.systemBoundaryDiagnostics.forcedBufferEvictions += 1
        }

        if state.systemAudioBuffer.count > AudioConfiguration.boundaryRetainedTailSamples {
            let trim = state.systemAudioBuffer.count - AudioConfiguration.boundaryRetainedTailSamples
            state.systemAudioBuffer.removeFirst(trim)
            mutated = true
        }

        if mutated {
            state.systemBufferVersion += 1
        }

        state.systemProcessedSamples = 0
        state.systemSilenceFlushDone = false
        state.systemBoundaryCooldownVersion = state.systemBufferVersion
        state.systemBoundaryFlushInFlight = false
        state.systemBoundaryDiagnostics.retainedTailSamples = state.systemAudioBuffer.count
        return nil
    }

    private func commitBoundaryDecisionMic(
        state: inout BufferState,
        snapshot: BoundarySnapshot,
        decision: BoundaryDecision,
        source: String,
        isFinalization: Bool
    ) -> PendingTranscription? {
        guard state.micBoundaryFlushInFlight else { return nil }
        guard snapshot.bufferVersion == state.micBufferVersion else {
            state.micBoundaryFlushInFlight = false
            return nil
        }

        state.micBoundaryDiagnostics.boundaryFallbackAttempted += decision.boundaryFallbackAttempted ? 1 : 0
        state.micBoundaryDiagnostics.boundaryFallbackSucceeded += decision.boundaryFallbackSucceeded ? 1 : 0
        state.micBoundaryDiagnostics.skippedPartialStrict += decision.strictDecision.passed ? 0 : 1
        state.micBoundaryDiagnostics.skippedPartialBoundary += decision.boundaryFallbackAttempted &&
            !decision.boundaryFallbackSucceeded ? 1 : 0

        if decision.shouldTranscribe {
            let consumeCount = min(snapshot.samples.count, state.micAudioBuffer.count)
            if consumeCount > 0 {
                state.micAudioBuffer.removeFirst(consumeCount)
                state.micBufferVersion += 1
            }
            state.micProcessedSamples = 0
            state.micChunksProcessed = 0
            state.micSilenceFlushDone = true
            state.micBoundaryRetryCount = 0
            state.micBoundaryCooldownVersion = nil
            state.micBoundaryFlushInFlight = false
            state.micBoundaryDiagnostics.retainedTailSamples = state.micAudioBuffer.count
            return PendingTranscription(
                samples: snapshot.samples,
                speaker: .me,
                startTime: snapshot.startTime,
                cumulativeOffset: snapshot.cumulativeOffset,
                contextSuffix: snapshot.contextSuffix,
                source: source
            )
        }

        if isFinalization {
            let consumeCount = min(snapshot.samples.count, state.micAudioBuffer.count)
            if consumeCount > 0 {
                state.micAudioBuffer.removeFirst(consumeCount)
                state.micBufferVersion += 1
            }
            state.micProcessedSamples = 0
            state.micChunksProcessed = 0
            state.micSilenceFlushDone = true
            state.micBoundaryRetryCount = 0
            state.micBoundaryCooldownVersion = nil
            state.micBoundaryFlushInFlight = false
            state.micBoundaryDiagnostics.retainedTailSamples = state.micAudioBuffer.count
            return nil
        }

        var mutated = false
        let nextRetry = state.micBoundaryRetryCount + 1
        if nextRetry > AudioConfiguration.boundaryMaxRetryCountPerWindow {
            let evict = min(AudioConfiguration.boundaryMinAdvanceSamples, state.micAudioBuffer.count)
            if evict > 0 {
                state.micAudioBuffer.removeFirst(evict)
                mutated = true
                state.micBoundaryDiagnostics.forcedBufferEvictions += 1
            }
            state.micBoundaryRetryCount = 0
        } else {
            state.micBoundaryRetryCount = nextRetry
        }

        if state.micAudioBuffer.count > AudioConfiguration.boundaryMaxRetentionSamples {
            let overflow = state.micAudioBuffer.count - AudioConfiguration.boundaryMaxRetentionSamples
            state.micAudioBuffer.removeFirst(overflow)
            mutated = true
            state.micBoundaryDiagnostics.forcedBufferEvictions += 1
        }

        if state.micAudioBuffer.count > AudioConfiguration.boundaryRetainedTailSamples {
            let trim = state.micAudioBuffer.count - AudioConfiguration.boundaryRetainedTailSamples
            state.micAudioBuffer.removeFirst(trim)
            mutated = true
        }

        if mutated {
            state.micBufferVersion += 1
        }

        state.micProcessedSamples = 0
        state.micSilenceFlushDone = false
        state.micBoundaryCooldownVersion = state.micBufferVersion
        state.micBoundaryFlushInFlight = false
        state.micBoundaryDiagnostics.retainedTailSamples = state.micAudioBuffer.count
        return nil
    }

    private func logBoundaryDiagnosticsSummary() {
        let snapshot = bufferState.withLock { state in
            BoundaryMetricsSnapshot(
                systemBoundaryFallbackAttempted: state.systemBoundaryDiagnostics.boundaryFallbackAttempted,
                systemBoundaryFallbackSucceeded: state.systemBoundaryDiagnostics.boundaryFallbackSucceeded,
                systemForcedBufferEvictions: state.systemBoundaryDiagnostics.forcedBufferEvictions,
                systemRetainedTailSamples: state.systemBoundaryDiagnostics.retainedTailSamples,
                systemSkippedPartialStrict: state.systemBoundaryDiagnostics.skippedPartialStrict,
                systemSkippedPartialBoundary: state.systemBoundaryDiagnostics.skippedPartialBoundary,
                micBoundaryFallbackAttempted: state.micBoundaryDiagnostics.boundaryFallbackAttempted,
                micBoundaryFallbackSucceeded: state.micBoundaryDiagnostics.boundaryFallbackSucceeded,
                micForcedBufferEvictions: state.micBoundaryDiagnostics.forcedBufferEvictions,
                micRetainedTailSamples: state.micBoundaryDiagnostics.retainedTailSamples,
                micSkippedPartialStrict: state.micBoundaryDiagnostics.skippedPartialStrict,
                micSkippedPartialBoundary: state.micBoundaryDiagnostics.skippedPartialBoundary,
                systemBufferedSamples: state.systemAudioBuffer.count,
                micBufferedSamples: state.micAudioBuffer.count
            )
        }

        Task {
            await DiagnosticLogger.shared.log(
                .transcription,
                "Boundary summary: " +
                "sysFallback=\(snapshot.systemBoundaryFallbackAttempted)/\(snapshot.systemBoundaryFallbackSucceeded), " +
                "sysEvictions=\(snapshot.systemForcedBufferEvictions), " +
                "sysRetained=\(snapshot.systemRetainedTailSamples), " +
                "sysSkipped=\(snapshot.systemSkippedPartialStrict)/\(snapshot.systemSkippedPartialBoundary), " +
                "micFallback=\(snapshot.micBoundaryFallbackAttempted)/\(snapshot.micBoundaryFallbackSucceeded), " +
                "micEvictions=\(snapshot.micForcedBufferEvictions), " +
                "micRetained=\(snapshot.micRetainedTailSamples), " +
                "micSkipped=\(snapshot.micSkippedPartialStrict)/\(snapshot.micSkippedPartialBoundary)"
            )
        }
    }

    struct BoundaryMetricsSnapshot: Sendable {
        let systemBoundaryFallbackAttempted: Int
        let systemBoundaryFallbackSucceeded: Int
        let systemForcedBufferEvictions: Int
        let systemRetainedTailSamples: Int
        let systemSkippedPartialStrict: Int
        let systemSkippedPartialBoundary: Int
        let micBoundaryFallbackAttempted: Int
        let micBoundaryFallbackSucceeded: Int
        let micForcedBufferEvictions: Int
        let micRetainedTailSamples: Int
        let micSkippedPartialStrict: Int
        let micSkippedPartialBoundary: Int
        let systemBufferedSamples: Int
        let micBufferedSamples: Int
    }

    // MARK: - Deterministic Test Hooks

    func testingSetVADEvaluator(_ evaluator: VADEvaluator?) {
        vadEvaluatorOverride = evaluator
    }

    func testingSetTranscriptionExecutor(_ executor: TranscriptionExecutor?) {
        transcriptionExecutorOverride = executor
    }

    func testingPrimeBoundaryState(
        systemSamples: [Float] = [],
        micSamples: [Float] = [],
        lastVoiceTime: Date,
        systemRetryCount: Int = 0,
        micRetryCount: Int = 0,
        recordingStartTime: Date = Date()
    ) {
        bufferState.withLock { state in
            state.recordingStartTime = recordingStartTime

            state.systemAudioBuffer = systemSamples
            state.systemTotalSamplesReceived = systemSamples.count
            state.systemProcessedSamples = 0
            state.systemChunksProcessed = systemSamples.isEmpty ? 0 : 1
            state.systemLastVoiceTime = systemSamples.isEmpty ? nil : lastVoiceTime
            state.systemSilenceFlushDone = false
            state.systemBufferVersion += 1
            state.systemBoundaryRetryCount = systemRetryCount
            state.systemBoundaryCooldownVersion = nil
            state.systemBoundaryFlushInFlight = false

            state.micAudioBuffer = micSamples
            state.micTotalSamplesReceived = micSamples.count
            state.micProcessedSamples = 0
            state.micChunksProcessed = micSamples.isEmpty ? 0 : 1
            state.micLastVoiceTime = micSamples.isEmpty ? nil : lastVoiceTime
            state.micSilenceFlushDone = false
            state.micBufferVersion += 1
            state.micBoundaryRetryCount = micRetryCount
            state.micBoundaryCooldownVersion = nil
            state.micBoundaryFlushInFlight = false
        }
    }

    func testingPerformSilenceFlushIfNeeded(now: Date = Date()) async {
        await performSilenceFlushIfNeeded(whisperKit: whisperKit, now: now)
    }

    func testingProcessRemainingAudio() async {
        await processRemainingAudio()
    }

    func testingBoundaryMetricsSnapshot() -> BoundaryMetricsSnapshot {
        bufferState.withLock { state in
            BoundaryMetricsSnapshot(
                systemBoundaryFallbackAttempted: state.systemBoundaryDiagnostics.boundaryFallbackAttempted,
                systemBoundaryFallbackSucceeded: state.systemBoundaryDiagnostics.boundaryFallbackSucceeded,
                systemForcedBufferEvictions: state.systemBoundaryDiagnostics.forcedBufferEvictions,
                systemRetainedTailSamples: state.systemBoundaryDiagnostics.retainedTailSamples,
                systemSkippedPartialStrict: state.systemBoundaryDiagnostics.skippedPartialStrict,
                systemSkippedPartialBoundary: state.systemBoundaryDiagnostics.skippedPartialBoundary,
                micBoundaryFallbackAttempted: state.micBoundaryDiagnostics.boundaryFallbackAttempted,
                micBoundaryFallbackSucceeded: state.micBoundaryDiagnostics.boundaryFallbackSucceeded,
                micForcedBufferEvictions: state.micBoundaryDiagnostics.forcedBufferEvictions,
                micRetainedTailSamples: state.micBoundaryDiagnostics.retainedTailSamples,
                micSkippedPartialStrict: state.micBoundaryDiagnostics.skippedPartialStrict,
                micSkippedPartialBoundary: state.micBoundaryDiagnostics.skippedPartialBoundary,
                systemBufferedSamples: state.systemAudioBuffer.count,
                micBufferedSamples: state.micAudioBuffer.count
            )
        }
    }
    
    // MARK: - Decoding Options
    
    /// Build optimized DecodingOptions for transcription.
    /// When previousText is provided, encodes it as promptTokens to condition the decoder
    /// on prior context (improves capitalization, proper nouns, cross-chunk continuity).
    private func buildDecodingOptions(previousText: String? = nil) -> DecodingOptions {
        var promptTokens: [Int]?
        if let text = previousText, !text.isEmpty, let tokenizer = whisperKit?.tokenizer {
            let encoded = tokenizer.encode(text: text)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            if !encoded.isEmpty {
                promptTokens = encoded
                let tokenCount = encoded.count
                Task { await DiagnosticLogger.shared.log(.transcription,
                    "Context chaining: \(tokenCount) prompt tokens from \(text.count) chars") }
            }
        }
        return DecodingOptions(
            language: "en",
            temperature: 0.0,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            usePrefillCache: true,
            promptTokens: promptTokens,
            suppressBlank: true,
            compressionRatioThreshold: 1.8,
            logProbThreshold: -1.0,
            firstTokenLogProbThreshold: -1.5,
            noSpeechThreshold: 0.5
        )
    }

    @discardableResult
    private func executeTranscription(
        _ samples: [Float],
        speaker: TranscriptSegment.Speaker,
        whisperKit: WhisperKit?,
        startTime: Date,
        cumulativeSampleOffset: Int = 0,
        previousText: String? = nil
    ) async -> String? {
        if let override = transcriptionExecutorOverride {
            let text = await override(
                samples,
                speaker,
                startTime,
                cumulativeSampleOffset,
                previousText
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let text, !text.isEmpty else { return nil }
            await emitTranscribedText(
                text: text,
                speaker: speaker,
                cumulativeSampleOffset: cumulativeSampleOffset
            )
            return text
        }

        guard let whisperKit else { return nil }
        return await transcribeChunk(
            samples,
            speaker: speaker,
            whisperKit: whisperKit,
            startTime: startTime,
            cumulativeSampleOffset: cumulativeSampleOffset,
            previousText: previousText
        )
    }

    private func emitTranscribedText(
        text: String,
        speaker: TranscriptSegment.Speaker,
        cumulativeSampleOffset: Int
    ) async {
        let segment = TranscriptSegment(
            text: text,
            timestamp: Double(cumulativeSampleOffset) / Double(sampleRate),
            speaker: speaker
        )

        if let stabilizer = liveStabilizer, transcriptionMode == .live {
            let output = await stabilizer.ingest(segment)
            for committed in output.committedSegments {
                transcriptHandler?(committed)
            }
            if let draft = output.draftUpdate {
                draftHandler?(draft.text, draft.speaker)
            }
        } else {
            transcriptHandler?(segment)
        }
    }
    
    /// Transcribe an audio chunk and return the result text for context chaining.
    /// If promptTokens cause an empty result (WhisperKit #372), retries without context.
    @discardableResult
    private func transcribeChunk(
        _ samples: [Float],
        speaker: TranscriptSegment.Speaker,
        whisperKit: WhisperKit,
        startTime: Date,
        cumulativeSampleOffset: Int = 0,
        previousText: String? = nil
    ) async -> String? {
        do {
            var options = buildDecodingOptions(previousText: previousText)
            var results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)

            // Retry without prompt tokens if we got an empty result with active context.
            // WhisperKit issue #372: promptTokens can trigger false "no speech" detection.
            if (results.first?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                && previousText != nil {
                Task { await DiagnosticLogger.shared.log(.transcription,
                    "Context retry: empty result with promptTokens, retrying without context for \(speaker.rawValue)") }
                options = buildDecodingOptions(previousText: nil)
                results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
            }

            guard let result = results.first,
                  !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }

            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            await emitTranscribedText(
                text: text,
                speaker: speaker,
                cumulativeSampleOffset: cumulativeSampleOffset
            )
            return text
        } catch {
            logger.error("Transcription error: \(error.localizedDescription)")
            
            let details = """
                Transcription chunk failed.
                Error: \(error.localizedDescription)
                Speaker: \(speaker.rawValue)
                Samples: \(samples.count)
                
                Transcription will continue with subsequent audio chunks.
                """
            warningHandler?("Transcription error", details)
            return nil
        }
    }
    
    // MARK: - Voice Activity Detection
    
    private func evaluateVoiceActivity(_ samples: [Float], mode: VADMode) -> VADDecision {
        if let override = vadEvaluatorOverride {
            return override(samples, mode)
        }

        guard !samples.isEmpty else {
            return VADDecision(
                passed: false,
                mode: mode,
                reason: .droppedTooShort,
                rms: 0,
                significantRatio: 0,
                sampleCount: 0
            )
        }

        let threshold: Float
        let minimumSamples: Int
        let minimumSignificantRatio: Float
        switch mode {
        case .strict:
            threshold = vadThreshold
            minimumSamples = AudioConfiguration.strictMinimumSamples
            minimumSignificantRatio = AudioConfiguration.strictSignificantRatio
        case .boundary:
            threshold = AudioConfiguration.boundaryVadThreshold
            minimumSamples = AudioConfiguration.boundaryMinimumSamples
            minimumSignificantRatio = AudioConfiguration.boundarySignificantRatio
        }

        // Calculate RMS (Root Mean Square) energy
        let sumSquares = samples.reduce(0.0) { $0 + ($1 * $1) }
        let rms = sqrt(sumSquares / Float(samples.count))
        guard rms > threshold else {
            return VADDecision(
                passed: false,
                mode: mode,
                reason: .droppedBelowRMS,
                rms: rms,
                significantRatio: 0,
                sampleCount: samples.count
            )
        }

        guard samples.count >= minimumSamples else {
            return VADDecision(
                passed: false,
                mode: mode,
                reason: .droppedTooShort,
                rms: rms,
                significantRatio: 0,
                sampleCount: samples.count
            )
        }

        // Energy distribution check: reject chunks with sparse energy
        let significantThreshold = threshold * 0.5
        let significantSamples = samples.filter { abs($0) > significantThreshold }.count
        let significantRatio = Float(significantSamples) / Float(samples.count)
        guard significantRatio >= minimumSignificantRatio else {
            return VADDecision(
                passed: false,
                mode: mode,
                reason: .droppedSparseEnergy,
                rms: rms,
                significantRatio: significantRatio,
                sampleCount: samples.count
            )
        }

        return VADDecision(
            passed: true,
            mode: mode,
            reason: mode == .strict ? .strictPassed : .boundaryPassed,
            rms: rms,
            significantRatio: significantRatio,
            sampleCount: samples.count
        )
    }
    
    // MARK: - Post-Processing Transcription
    
    /// Transcribe entire audio files after recording (post-processing mode)
    /// Uses 30-second chunks with 5-second overlap for optimal Whisper performance
    /// - Parameters:
    ///   - systemAudioURL: URL to system audio file
    ///   - micAudioURL: URL to microphone audio file
    ///   - startTime: Recording start time for timestamp calculation
    func transcribePostProcessing(
        systemAudioURL: URL?,
        micAudioURL: URL?,
        startTime: Date
    ) async throws {
        guard isInitialized,
              let whisperKit = whisperKit
        else {
            throw NSError(
                domain: "TranscriptionService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "WhisperKit not initialized"]
            )
        }
        
        let chunkDuration = AudioConfiguration.postProcessingChunkDuration
        let overlap = AudioConfiguration.postProcessingOverlapDuration
        
        // Transcribe system audio if available (with chunking and deduplication)
        if let systemURL = systemAudioURL {
            try Task.checkCancellation()
            if let samples = await loadAudioFile(url: systemURL) {
                let duration = String(format: "%.1f", Double(samples.count) / Double(self.sampleRate))
                logger.info("Post-processing system audio: \(samples.count) samples (\(duration)s)")
                
                let chunks = splitIntoChunks(
                    samples: samples,
                    chunkDuration: chunkDuration,
                    overlap: overlap
                )
                
                logger.info("Split system audio into \(chunks.count) chunks")
                
                try await processChunksWithDeduplication(
                    chunks: chunks,
                    speaker: .them,
                    chunkDuration: chunkDuration,
                    overlap: overlap,
                    whisperKit: whisperKit
                )
            }
        }
        
        // Transcribe mic audio if available (with chunking and deduplication)
        if let micURL = micAudioURL {
            try Task.checkCancellation()
            if let samples = await loadAudioFile(url: micURL) {
                let duration = String(format: "%.1f", Double(samples.count) / Double(self.sampleRate))
                logger.info("Post-processing mic audio: \(samples.count) samples (\(duration)s)")
                
                let chunks = splitIntoChunks(
                    samples: samples,
                    chunkDuration: chunkDuration,
                    overlap: overlap
                )
                
                logger.info("Split mic audio into \(chunks.count) chunks")
                
                try await processChunksWithDeduplication(
                    chunks: chunks,
                    speaker: .me,
                    chunkDuration: chunkDuration,
                    overlap: overlap,
                    whisperKit: whisperKit
                )
            }
        }
    }
    
    /// Process audio chunks with timestamp-based deduplication
    ///
    /// This method handles the overlap between chunks by tracking a "coverage boundary"
    /// and only emitting segments that start at or after this boundary. This prevents
    /// duplicate transcription when chunks overlap (e.g., 5-second overlap in 30-second chunks).
    ///
    /// - Parameters:
    ///   - chunks: Audio chunks with timestamps (from splitIntoChunks)
    ///   - speaker: Speaker label for segments (.me or .them)
    ///   - chunkDuration: Duration of each chunk in seconds (e.g., 30.0)
    ///   - overlap: Overlap duration between chunks in seconds (e.g., 5.0)
    ///   - whisperKit: WhisperKit instance for transcription
    ///
    /// - Note: Assumes overlap < chunkDuration (e.g., 5s < 30s per AudioConfiguration)
    private func processChunksWithDeduplication(
        chunks: [(samples: [Float], timestamp: TimeInterval)],
        speaker: TranscriptSegment.Speaker,
        chunkDuration: TimeInterval,
        overlap: TimeInterval,
        whisperKit: WhisperKit
    ) async throws {
        // Effective chunk duration is the non-overlapping portion
        let effectiveChunkDuration = chunkDuration - overlap
        
        // Track coverage boundary for deduplication
        // Segments starting before this boundary have already been emitted
        var coverageBoundary: TimeInterval = 0.0
        
        // Tolerance for floating-point comparison (10ms)
        let tolerance: TimeInterval = 0.01
        
        // Counters for summary logging
        var emittedCount = 0
        var skippedCount = 0
        
        // Log dedup start
        Task { await DiagnosticLogger.shared.log(.transcription,
            "Dedup started: chunks=\(chunks.count), speaker=\(speaker.rawValue), " +
            "effectiveDuration=\(effectiveChunkDuration)s") }
        
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let options = buildDecodingOptions()
            let results = try await whisperKit.transcribe(audioArray: chunk.samples, decodeOptions: options)
            
            // Log chunk results
            Task { await DiagnosticLogger.shared.log(.transcription,
                "Chunk#\(index): resultsCount=\(results.count)") }
            
            for result in results where !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Log segment availability (CRITICAL for path detection)
                Task { await DiagnosticLogger.shared.log(.transcription,
                    "Result: segmentsEmpty=\(result.segments.isEmpty), segCount=\(result.segments.count)") }
                
                // Fallback: if segments array is empty, use result.text with chunk timestamp
                if result.segments.isEmpty {
                    // Only emit if this chunk's content starts at or after coverage boundary
                    if chunk.timestamp >= coverageBoundary - tolerance {
                        let segment = TranscriptSegment(
                            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                            timestamp: chunk.timestamp,
                            speaker: speaker
                        )
                        transcriptHandler?(segment)
                        emittedCount += 1
                        // Pre-capture values for Sendable closure
                        let logTs = chunk.timestamp
                        let logText = String(segment.text.prefix(30))
                        Task { await DiagnosticLogger.shared.log(.transcription,
                            "EMIT[fallback]: ts=\(logTs), text=\"\(logText)...\"") }
                    } else {
                        skippedCount += 1
                        // Pre-capture values for Sendable closure
                        let logChunkTs = chunk.timestamp
                        let logBoundary = coverageBoundary
                        Task { await DiagnosticLogger.shared.log(.transcription,
                            "SKIP[fallback]: chunkTs=\(logChunkTs) < boundary=\(logBoundary)") }
                    }
                } else {
                    // Use segment-level timestamps for precise deduplication
                    for seg in result.segments {
                        let segmentText = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !segmentText.isEmpty else { continue }
                        
                        // Calculate absolute timestamp (chunk start + segment offset within chunk)
                        // seg.start is Float, convert to TimeInterval (Double)
                        let absoluteStart = chunk.timestamp + TimeInterval(seg.start)
                        
                        // Log segment details - pre-capture values for Sendable closure
                        let logSegStart = seg.start
                        let logAbsStart = absoluteStart
                        let logBoundary = coverageBoundary
                        Task { await DiagnosticLogger.shared.log(.transcription,
                            "Segment: start=\(logSegStart), absStart=\(logAbsStart), boundary=\(logBoundary)") }
                        
                        // Only emit segments that start at or after coverage boundary
                        if absoluteStart >= coverageBoundary - tolerance {
                            let transcriptSegment = TranscriptSegment(
                                text: segmentText,
                                timestamp: absoluteStart,
                                speaker: speaker
                            )
                            transcriptHandler?(transcriptSegment)
                            emittedCount += 1
                            // Pre-capture values for Sendable closure
                            let logEmitTs = absoluteStart
                            let logEmitText = String(segmentText.prefix(30))
                            Task { await DiagnosticLogger.shared.log(.transcription,
                                "EMIT[segment]: ts=\(logEmitTs), text=\"\(logEmitText)...\"") }
                        } else {
                            skippedCount += 1
                            // Pre-capture values for Sendable closure
                            let logSkipTs = absoluteStart
                            let logSkipBoundary = coverageBoundary
                            Task { await DiagnosticLogger.shared.log(.transcription,
                                "SKIP[segment]: absStart=\(logSkipTs) < boundary=\(logSkipBoundary)") }
                        }
                    }
                }
            }
            
            // Update coverage boundary for next chunk
            // Next chunk's unique content starts at: chunk.timestamp + effectiveChunkDuration
            coverageBoundary = chunk.timestamp + effectiveChunkDuration
            
            // Log boundary update - pre-capture values for Sendable closure
            let logIdx = index
            let logNewBoundary = coverageBoundary
            Task { await DiagnosticLogger.shared.log(.transcription,
                "Dedup boundary: chunk#\(logIdx) -> \(logNewBoundary)s") }
            
            // Log progress
            if (index + 1) % 5 == 0 || index == chunks.count - 1 {
                logger.info("Processed \(speaker.rawValue) audio chunk \(index + 1)/\(chunks.count)")
            }
        }
        
        // Log summary at method exit - pre-capture values for Sendable closure
        let logSpeaker = speaker.rawValue
        let logEmitted = emittedCount
        let logSkipped = skippedCount
        Task { await DiagnosticLogger.shared.log(.transcription,
            "Dedup complete: speaker=\(logSpeaker), emitted=\(logEmitted), skipped=\(logSkipped)") }
    }
    
    /// Split audio samples into chunks with overlap for post-processing
    /// - Parameters:
    ///   - samples: Audio samples to split
    ///   - chunkDuration: Duration of each chunk in seconds
    ///   - overlap: Overlap duration between chunks in seconds
    /// - Returns: Array of tuples containing chunk samples and their timestamp offsets
    private func splitIntoChunks(
        samples: [Float],
        chunkDuration: TimeInterval,
        overlap: TimeInterval
    ) -> [(samples: [Float], timestamp: TimeInterval)] {
        let chunkSamples = Int(chunkDuration * Double(sampleRate))
        let overlapSamples = Int(overlap * Double(sampleRate))
        let stride = chunkSamples - overlapSamples
        
        // Log chunking parameters
        Task { await DiagnosticLogger.shared.log(.transcription,
            "Chunking: samples=\(samples.count), chunkDuration=\(chunkDuration)s, " +
            "overlap=\(overlap)s, stride=\(stride)") }
        
        var chunks: [(samples: [Float], timestamp: TimeInterval)] = []
        var offset = 0
        
        while offset < samples.count {
            let endOffset = min(offset + chunkSamples, samples.count)
            let chunkArray = Array(samples[offset..<endOffset])
            
            // Calculate timestamp for this chunk
            let timestamp = Double(offset) / Double(sampleRate)
            
            chunks.append((samples: chunkArray, timestamp: timestamp))
            
            // Move forward by stride (chunk size - overlap)
            offset += stride
            
            // If we're at the end and have a tiny remaining chunk, break
            if offset >= samples.count {
                break
            }
        }
        
        return chunks
    }
    
    /// Load audio file and convert to Float32 samples at 16kHz mono
    ///
    /// - Warning: AVAudioConverter returns different status codes that must be handled correctly:
    ///   - `.haveData` (rawValue 0): Output buffer has data, more input available
    ///   - `.inputRanDry` (rawValue 1): Input exhausted BUT output buffer has valid data - THIS IS SUCCESS!
    ///   - `.endOfStream` (rawValue 2): End of stream reached
    ///   - `.error` (rawValue 3): An error occurred
    ///   See: https://developer.apple.com/documentation/avfaudio/avaudioconverteroutputstatus
    private func loadAudioFile(url: URL) async -> [Float]? {
        do {
            let file = try AVAudioFile(forReading: url)
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            )!
            
            guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
                logger.error("Failed to create audio converter")
                return nil
            }
            
            let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            )!
            try file.read(into: inputBuffer)
            
            let outputFrameCount = Int(
                Double(inputBuffer.frameLength) * targetFormat.sampleRate / file.processingFormat.sampleRate
            )
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AVAudioFrameCount(outputFrameCount)
            ) else {
                return nil
            }
            
            var error: NSError?
            let inputBufferRef = inputBuffer  // Capture for closure
            var inputProvided = OSAllocatedUnfairLock(initialState: false)
            let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                let wasProvided = inputProvided.withLock {
                    if !$0 {
                        $0 = true
                        return false
                    }
                    return true
                }
                if !wasProvided {
                    outStatus.pointee = .haveData
                    return inputBufferRef
                } else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
            }
            
            // IMPORTANT: Accept both .haveData AND .inputRanDry as valid statuses!
            // .inputRanDry (rawValue 1) means input was exhausted but output buffer contains valid data.
            // This is a SUCCESSFUL conversion - the output is ready to use.
            // Bug fix: Previously only checked for .haveData, which incorrectly rejected valid conversions.
            let isValidStatus = (status == .haveData || status == .inputRanDry)
            guard isValidStatus, let floatChannelData = outputBuffer.floatChannelData else {
                logger.error("Conversion failed: \(error?.localizedDescription ?? "unknown error")")
                return nil
            }
            
            let frameLength = Int(outputBuffer.frameLength)
            return Array(UnsafeBufferPointer(start: floatChannelData[0], count: frameLength))
        } catch {
            logger.error("Failed to load audio file: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Audio Resampling Utilities

extension TranscriptionService {
    /// Convert Int16 CMSampleBuffer (microphone) to Float32 samples at 16kHz mono
    /// Handles stereo to mono conversion if needed
    /// - Parameter sampleBuffer: The audio sample buffer containing Int16 samples
    /// - Returns: Float32 samples at 16kHz mono, or nil if conversion fails
    static func convertInt16ToWhisperFormat(_ sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }
        
        // Get format info
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        
        let channelCount = Int(asbd.pointee.mChannelsPerFrame)
        let bitsPerChannel = Int(asbd.pointee.mBitsPerChannel)
        let isFloat = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )
        
        guard status == kCMBlockBufferNoErr, let data = dataPointer else {
            return nil
        }
        
        // Calculate sample count
        let bytesPerSample = bitsPerChannel / 8
        let totalSamples = length / bytesPerSample
        let frameCount = totalSamples / channelCount
        
        var floatSamples: [Float]
        
        if isFloat && bitsPerChannel == 32 {
            // Already Float32 - just extract and convert stereo to mono
            let floatPointer = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: totalSamples)
            if channelCount == 2 {
                floatSamples = (0..<frameCount).map { i in
                    (floatPointer[i * 2] + floatPointer[i * 2 + 1]) / 2.0
                }
            } else {
                floatSamples = Array(UnsafeBufferPointer(start: floatPointer, count: frameCount))
            }
        } else if !isFloat && bitsPerChannel == 16 {
            // Int16 - convert to Float32 and optionally stereo to mono
            let int16Pointer = UnsafeRawPointer(data).bindMemory(to: Int16.self, capacity: totalSamples)
            
            if channelCount == 2 {
                // Stereo to mono: average left and right channels
                floatSamples = (0..<frameCount).map { i in
                    let left = Float(int16Pointer[i * 2]) / Float(Int16.max)
                    let right = Float(int16Pointer[i * 2 + 1]) / Float(Int16.max)
                    return (left + right) / 2.0
                }
            } else {
                // Mono: just convert
                floatSamples = (0..<frameCount).map { i in
                    Float(int16Pointer[i]) / Float(Int16.max)
                }
            }
        } else {
            return nil
        }
        
        return floatSamples
    }
    
    /// Convert CMSampleBuffer to Float32 samples at 16kHz mono using AVAudioConverter for high-quality resampling
    /// - Parameters:
    ///   - sampleBuffer: The audio sample buffer
    ///   - sourceSampleRate: Original sample rate (e.g., 48000 or 24000)
    ///   - sourceChannels: Number of source channels (1 or 2)
    /// - Returns: Resampled Float32 samples at 16kHz mono, or nil if conversion fails
    static func resampleToWhisperFormat(
        _ sampleBuffer: CMSampleBuffer,
        sourceSampleRate: Double,
        sourceChannels: Int
    ) -> [Float]? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }
        
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )
        
        guard status == kCMBlockBufferNoErr, let data = dataPointer else {
            return nil
        }
        
        // Convert bytes to Float32 samples
        // Note: CMSampleBuffer from ScreenCaptureKit provides interleaved audio
        let floatCount = length / MemoryLayout<Float>.size
        let floatPointer = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: floatCount)
        let rawSamples = Array(UnsafeBufferPointer(start: floatPointer, count: floatCount))
        
        // Use AVAudioConverter for high-quality resampling
        // Note: rawSamples are interleaved if stereo, so we need to handle that
        return resampleWithAVAudioConverter(
            samples: rawSamples,
            sourceSampleRate: sourceSampleRate,
            sourceChannels: sourceChannels,
            targetSampleRate: 16000,
            targetChannels: 1,
            isInterleaved: true  // CMSampleBuffer provides interleaved audio
        )
    }

    /// Resample pre-extracted Float samples to WhisperKit format (16kHz mono).
    /// Used by the AEC pipeline which delivers already-extracted mono 48kHz samples.
    static func resampleToWhisperFormat(
        _ samples: [Float],
        sourceSampleRate: Double,
        sourceChannels: Int
    ) -> [Float] {
        return resampleWithAVAudioConverter(
            samples: samples,
            sourceSampleRate: sourceSampleRate,
            sourceChannels: sourceChannels,
            targetSampleRate: 16000,
            targetChannels: 1,
            isInterleaved: false  // Already mono, no interleaving
        ) ?? samples  // Pass-through on failure to preserve audio
    }

    /// Resample audio samples using AVAudioConverter
    /// - Parameters:
    ///   - samples: Input samples (mono or stereo, interleaved or not)
    ///   - sourceSampleRate: Source sample rate
    ///   - sourceChannels: Number of source channels
    ///   - targetSampleRate: Target sample rate
    ///   - targetChannels: Number of target channels
    ///   - isInterleaved: Whether input samples are interleaved
    /// - Returns: Resampled samples, or nil if conversion fails
    static func resampleSamples(
        samples: [Float],
        sourceSampleRate: Double,
        sourceChannels: Int,
        targetSampleRate: Double,
        targetChannels: Int,
        isInterleaved: Bool = false
    ) -> [Float]? {
        return resampleWithAVAudioConverter(
            samples: samples,
            sourceSampleRate: sourceSampleRate,
            sourceChannels: sourceChannels,
            targetSampleRate: targetSampleRate,
            targetChannels: targetChannels,
            isInterleaved: isInterleaved
        )
    }
    
    /// High-quality resampling using AVAudioConverter
    private static func resampleWithAVAudioConverter(
        samples: [Float],
        sourceSampleRate: Double,
        sourceChannels: Int,
        targetSampleRate: Double,
        targetChannels: Int,
        isInterleaved: Bool = false
    ) -> [Float]? {
        // If no conversion needed, return as-is (but convert stereo to mono if needed)
        if sourceSampleRate == targetSampleRate && sourceChannels == targetChannels {
            return samples
        }
        
        // Create source format (non-interleaved for AVAudioPCMBuffer)
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: AVAudioChannelCount(sourceChannels),
            interleaved: false
        ) else {
            return fallbackResample(
                samples: samples,
                sourceSampleRate: sourceSampleRate,
                sourceChannels: sourceChannels,
                targetSampleRate: targetSampleRate,
                targetChannels: targetChannels
            )
        }
        
        // Create target format
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: AVAudioChannelCount(targetChannels),
            interleaved: false
        ) else {
            return fallbackResample(
                samples: samples,
                sourceSampleRate: sourceSampleRate,
                sourceChannels: sourceChannels,
                targetSampleRate: targetSampleRate,
                targetChannels: targetChannels
            )
        }
        
        // Create converter
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            return fallbackResample(
                samples: samples,
                sourceSampleRate: sourceSampleRate,
                sourceChannels: sourceChannels,
                targetSampleRate: targetSampleRate,
                targetChannels: targetChannels
            )
        }
        
        // Create input buffer
        let frameCount = samples.count / sourceChannels
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return fallbackResample(
                samples: samples,
                sourceSampleRate: sourceSampleRate,
                sourceChannels: sourceChannels,
                targetSampleRate: targetSampleRate,
                targetChannels: targetChannels
            )
        }
        
        inputBuffer.frameLength = AVAudioFrameCount(frameCount)
        
        // Copy samples to input buffer (deinterleave if needed)
        guard let channelData = inputBuffer.floatChannelData else {
            return fallbackResample(
                samples: samples,
                sourceSampleRate: sourceSampleRate,
                sourceChannels: sourceChannels,
                targetSampleRate: targetSampleRate,
                targetChannels: targetChannels
            )
        }
        
        if sourceChannels == 1 {
            samples.withUnsafeBufferPointer { ptr in
                channelData[0].update(from: ptr.baseAddress!, count: frameCount)
            }
        } else {
            // Deinterleave stereo samples
            if isInterleaved {
                // Samples are interleaved: L R L R L R...
                for i in 0..<frameCount {
                    channelData[0][i] = samples[i * 2]
                    channelData[1][i] = samples[i * 2 + 1]
                }
            } else {
                // Samples are already deinterleaved (unlikely but handle it)
                let halfCount = samples.count / 2
                samples.withUnsafeBufferPointer { ptr in
                    channelData[0].update(from: ptr.baseAddress!, count: halfCount)
                }
                samples[halfCount...].withUnsafeBufferPointer { ptr in
                    channelData[1].update(from: ptr.baseAddress!, count: halfCount)
                }
            }
        }
        
        // Calculate output buffer size
        let outputFrameCount = Int(Double(frameCount) * targetSampleRate / sourceSampleRate)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(outputFrameCount)
        ) else {
            return fallbackResample(
                samples: samples,
                sourceSampleRate: sourceSampleRate,
                sourceChannels: sourceChannels,
                targetSampleRate: targetSampleRate,
                targetChannels: targetChannels
            )
        }
        
        // Convert
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }
        
        guard status == .haveData, let outputChannelData = outputBuffer.floatChannelData else {
            return fallbackResample(
                samples: samples,
                sourceSampleRate: sourceSampleRate,
                sourceChannels: sourceChannels,
                targetSampleRate: targetSampleRate,
                targetChannels: targetChannels
            )
        }
        
        // Extract mono output
        let outputFrames = Int(outputBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: outputChannelData[0], count: outputFrames))
    }
    
    /// Fallback resampling using simple linear interpolation (used if AVAudioConverter fails)
    private static func fallbackResample(
        samples: [Float],
        sourceSampleRate: Double,
        sourceChannels: Int,
        targetSampleRate: Double,
        targetChannels: Int
    ) -> [Float] {
        var processed = samples
        
        // Convert stereo to mono if needed
        if sourceChannels == 2 && targetChannels == 1 {
            processed = stereoToMono(processed)
        }
        
        // Resample if needed
        if sourceSampleRate != targetSampleRate {
            processed = simpleResample(processed, from: sourceSampleRate, to: targetSampleRate)
        }
        
        return processed
    }
    
    /// Convert stereo samples to mono by averaging channels
    private static func stereoToMono(_ samples: [Float]) -> [Float] {
        var mono: [Float] = []
        mono.reserveCapacity(samples.count / 2)
        
        for i in stride(from: 0, to: samples.count - 1, by: 2) {
            let avg = (samples[i] + samples[i + 1]) / 2.0
            mono.append(avg)
        }
        
        return mono
    }
    
    /// Simple linear interpolation resampling (fallback)
    /// Note: vDSP interpolation is preferred for better quality
    private static func simpleResample(
        _ samples: [Float],
        from sourceSampleRate: Double,
        to targetSampleRate: Double
    ) -> [Float] {
        let ratio = sourceSampleRate / targetSampleRate
        let targetCount = Int(Double(samples.count) / ratio)
        
        var resampled: [Float] = []
        resampled.reserveCapacity(targetCount)
        
        for i in 0..<targetCount {
            let sourceIndex = Double(i) * ratio
            let lowerIndex = Int(sourceIndex)
            let upperIndex = min(lowerIndex + 1, samples.count - 1)
            let fraction = Float(sourceIndex - Double(lowerIndex))
            
            let interpolated = samples[lowerIndex] * (1 - fraction) + samples[upperIndex] * fraction
            resampled.append(interpolated)
        }
        
        return resampled
    }
}
