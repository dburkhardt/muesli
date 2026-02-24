import Foundation
import os.log

/// Coordinates transcription model lifecycle and audio buffering
/// Decouples transcription from recording - recording can start immediately,
/// while transcription loads asynchronously
@Observable
@MainActor
final class TranscriptionCoordinator {
    // MARK: - Types
    
    /// Model loading and readiness state
    enum ModelState: Sendable {
        case notAvailable      // No model downloaded
        case loading           // Model is being initialized
        case ready             // Model ready for transcription
        case failed(Error)     // Model loading failed
        
        /// Check if state is loading
        var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }
        
        /// Check if state is ready
        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }
    
    // MARK: - Dependencies
    
    private let logger = Logger(subsystem: "com.muesli.app", category: "TranscriptionCoordinator")
    private let transcriptionService: any TranscriptionServiceProtocol
    private let modelManager: any ModelManagerProtocol
    
    // MARK: - Callbacks
    
    /// Called when a meeting is updated (for export service integration)
    var onMeetingUpdated: ((MeetingHistoryItem) -> Void)?
    
    // MARK: - Live Refinement
    
    /// Whether live refinement is enabled (hidden preference for v0.1.2)
    var liveRefinementEnabled: Bool = false
    
    /// Queue of segments awaiting refinement
    private var liveRefinementQueue: [TranscriptSegment] = []
    
    /// Current segment being refined
    private var currentRefinementTask: Task<Void, Never>?
    
    /// Reference to refinement coordinator (set externally)
    weak var refinementCoordinator: RefinementCoordinator?
    
    /// Maximum queue depth before skipping refinement (avoid falling behind)
    private let maxRefinementQueueDepth = 5
    
    // MARK: - State
    
    /// Current model state
    /// Uses didSet to automatically flush buffered audio when state becomes ready
    var modelState: ModelState = .notAvailable {
        didSet {
            // Automatically flush buffered audio when both conditions are met
            if modelState.isReady && isInitialized {
                processBufferedAudio()
            }
        }
    }
    
    /// Whether transcription service is initialized
    /// Uses didSet to automatically flush buffered audio when initialization completes
    private var isInitialized: Bool = false {
        didSet {
            // Automatically flush buffered audio when both conditions are met
            if modelState.isReady && isInitialized {
                processBufferedAudio()
            }
        }
    }
    
    /// Audio buffering while model loads (protected by serial actor execution)
    private var pendingSystemAudio: [Float] = []
    private var pendingMicAudio: [Float] = []
    private var bufferStartTime: Date?
    
    /// Maximum buffer size (30 seconds at 16kHz = 480,000 samples)
    private let maxBufferSamples: Int = AudioConfiguration.maxBufferSamples
    
    /// Maximum buffering duration (5 minutes) before timeout
    /// Large models like v3 large can take up to 2+ minutes to compile on first use
    private let maxBufferDuration: TimeInterval = AudioConfiguration.bufferTimeoutSeconds
    
    /// Maximum retries for model loading to prevent infinite recursion
    private let maxModelRetries: Int = AudioConfiguration.maxModelRetries
    
    /// Current retry count
    private var retriesRemaining: Int = 3
    
    /// Callback when buffer timeout occurs
    var onBufferTimeout: (() -> Void)?
    
    /// Callback when model switches due to fallback (from, to, reason)
    var onModelSwitched: ((ModelManager.ModelSize, ModelManager.ModelSize, Error) -> Void)?
    
    /// Callback for transcription warnings (category, message, details, canRetry)
    var onWarning: ((ServiceWarning.WarningCategory, String, String, Bool) -> Void)?
    
    /// Callback when a warning should be dismissed (category)
    /// Called when model becomes ready to auto-dismiss the model loading warning
    var onWarningDismissed: ((ServiceWarning.WarningCategory) -> Void)?
    
    // MARK: - Model Load Timing
    
    /// When model loading started (for detecting slow loads)
    var modelLoadStartTime: Date?
    
    /// Whether model load is taking longer than expected (indicates first-time compilation)
    /// STORED property (not computed) so SwiftUI observes changes when Task sets it
    var isSlowModelLoad: Bool = false
    
    /// Threshold for "slow" load (indicates first-time compilation)
    /// Injectable for testing (default 10.0 seconds)
    private let slowLoadThreshold: TimeInterval
    
    /// Whether we've already shown the slow-load warning (to avoid repeated notifications)
    private var hasShownSlowLoadWarning: Bool = false
    
    /// Task for slow-load detection (stored for cancellation)
    private var slowLoadCheckTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    init(
        transcriptionService: any TranscriptionServiceProtocol,
        modelManager: any ModelManagerProtocol,
        slowLoadThreshold: TimeInterval = 10.0
    ) {
        self.transcriptionService = transcriptionService
        self.modelManager = modelManager
        self.slowLoadThreshold = slowLoadThreshold
    }
    
    // MARK: - Model Switching
    
    /// Whether a model switch is in progress (observable for UI)
    var isModelSwitching = false
    
    /// Switch to a different model during active transcription
    /// Audio continues buffering while new model loads
    func switchModel(to newModel: ModelManager.ModelSize) async -> ModelState {
        // Prevent concurrent model switches
        guard !isModelSwitching else {
            logger.warning("Model switch already in progress, ignoring request")
            return modelState
        }
        
        guard modelManager.validateModel(newModel) else {
            return .notAvailable
        }
        
        // Skip if already using this model
        guard modelManager.activeModel != newModel else {
            return modelState
        }
        
        isModelSwitching = true
        defer { isModelSwitching = false }
        
        let oldModel = modelManager.activeModel
        
        // Log the switch with buffer state (async call)
        await DiagnosticLogger.shared.log(.transcription,
            "Model switch: \(oldModel?.rawValue ?? "none") -> \(newModel.rawValue), " +
            "buffered=\(pendingSystemAudio.count + pendingMicAudio.count) samples")
        
        // CRITICAL: Set loading state FIRST - enables buffering before cleanup
        modelState = .loading
        isInitialized = false
        
        // Now safe to stop current transcription (new audio goes to buffer)
        await transcriptionService.stopTranscription()
        
        // Switch active model and reinitialize
        modelManager.setActiveModel(newModel)
        let result = await prepareModel()
        // processBufferedAudio() called automatically when ready via didSet
        
        // If switch failed, attempt to restart old model for recovery
        if case .failed = result, let oldModel = oldModel {
            logger.warning("Model switch failed, attempting to restore \(oldModel.displayName)")
            modelManager.setActiveModel(oldModel)
            let recoveryResult = await prepareModel()
            if recoveryResult.isReady {
                logger.info("Successfully restored \(oldModel.displayName)")
            }
            return result  // Still return failure so UI can show warning
        }
        
        return result
    }
    
    // MARK: - Model Lifecycle
    
    /// Reset per-recording state so new sessions can retry model loading
    func resetForNewRecording() {
        retriesRemaining = maxModelRetries
        if case .failed = modelState {
            modelState = .notAvailable
        }
        clearBuffers()
        
        // Reset slow-load detection state
        slowLoadCheckTask?.cancel()
        slowLoadCheckTask = nil
        modelLoadStartTime = nil
        isSlowModelLoad = false
        hasShownSlowLoadWarning = false
    }
    
    /// Check model availability and prepare for transcription
    /// Returns immediately with current state, loads async if needed
    func prepareModel() async -> ModelState {
        // Check retry limit to prevent infinite recursion
        guard retriesRemaining > 0 else {
            modelState = .failed(MuesliError.modelNotFound)
            return .failed(MuesliError.modelNotFound)
        }
        retriesRemaining -= 1
        
        // Check if model is available
        guard let activeModel = modelManager.activeModel else {
            modelState = .notAvailable
            return .notAvailable
        }

        // If the preferred model is still compiling/downloading, fall back to the first ready
        // model for this session so recording starts immediately without blocking the user.
        // The user's preference is unchanged — once the preferred model finishes compiling it
        // will be used in the next session.
        let modelToUse: ModelManager.ModelSize
        let activeState = modelManager.downloadState(for: activeModel)
        let isActiveModelBusy: Bool
        switch activeState {
        case .compiling, .downloading:
            isActiveModelBusy = true
        default:
            isActiveModelBusy = false
        }

        if isActiveModelBusy,
           let ready = modelManager.firstReadyModel,
           ready != activeModel {
            logger.info("MODEL_FALLBACK_FOR_SESSION: preferred=\(activeModel.rawValue) is busy (\(String(describing: activeState))), using \(ready.rawValue) for this session")
            Task {
                await DiagnosticLogger.shared.log(.transcription,
                    "MODEL_FALLBACK_FOR_SESSION: preferred=\(activeModel.rawValue) busy, fallback=\(ready.rawValue)")
            }
            modelToUse = ready
        } else {
            modelToUse = activeModel
        }
        
        // Validate model
        guard modelManager.validateModel(modelToUse),
              let modelPath = modelManager.pathForModel(modelToUse) else {
            // Only mark corrupted on validation errors (only applies to preferred active model)
            if modelToUse == activeModel {
                modelManager.markModelCorrupted(activeModel)
            }

            // Try fallback
            if let fallback = modelManager.getFirstValidModel() {
                modelManager.setActiveModel(fallback)

                // Notify user of model switch
                let error = MuesliError.modelCorrupted(modelName: "\(modelToUse)")
                onModelSwitched?(modelToUse, fallback, error)

                return await prepareModel()  // Retry with fallback
            }

            modelState = .notAvailable
            return .notAvailable
        }
        
        // If already initialized, return ready
        if isInitialized {
            modelState = .ready
            // Flush any buffered audio in case we resumed
            processBufferedAudio()
            // Reset retry count on success
            retriesRemaining = maxModelRetries
            return .ready
        }
        
        // Start loading
        modelState = .loading
        modelLoadStartTime = Date()
        isSlowModelLoad = false
        hasShownSlowLoadWarning = false
        
        // Cancel any previous slow-load check task
        slowLoadCheckTask?.cancel()
        
        // Capture threshold before Task (defensive - avoids nil self issues)
        let threshold = slowLoadThreshold
        
        // Start a managed task to detect slow loading and warn user
        slowLoadCheckTask = Task { @MainActor [weak self] in
            // Wait for threshold period
            try? await Task.sleep(for: .seconds(threshold))
            
            // Check if cancelled
            guard !Task.isCancelled else { return }
            guard let self = self else { return }
            
            // If still loading and haven't warned yet, notify user
            if self.modelState.isLoading && !self.hasShownSlowLoadWarning {
                self.isSlowModelLoad = true  // STORED - triggers SwiftUI observation
                self.hasShownSlowLoadWarning = true
                self.onWarning?(
                    .modelLoading,
                    "Model preparing for first use",
                    """
                    It looks like you're using this model for the first time. \
                    Transcription may be slow to start, but don't worry - your \
                    recording is active and audio is being captured.
                    
                    This is a one-time setup that may take a few minutes.
                    """,
                    false  // canRetry = false
                )
            }
        }
        
        do {
            try await transcriptionService.initialize(modelPath: modelPath)
            isInitialized = true
            modelState = .ready
            
            // Clean up slow-load detection (model loaded successfully)
            isSlowModelLoad = false
            slowLoadCheckTask?.cancel()
            slowLoadCheckTask = nil
            
            // Auto-dismiss the model loading warning (if one was shown)
            onWarningDismissed?(.modelLoading)
            
            // Flush any buffered audio collected during loading
            processBufferedAudio()
            // Reset retry count on success
            retriesRemaining = maxModelRetries
            return .ready
        } catch {
            modelState = .failed(error)

            // Only mark corrupted on specific initialization errors, not temporary failures
            if isInitializationError(error) {
                modelManager.markModelCorrupted(modelToUse)
            }

            if let fallback = modelManager.getFirstValidModel() {
                modelManager.setActiveModel(fallback)
                isInitialized = false

                // Notify user of model switch
                onModelSwitched?(modelToUse, fallback, error)

                return await prepareModel()  // Retry with fallback
            }

            return .failed(error)
        }
    }
    
    /// Check if error is a permanent initialization error (vs temporary)
    private func isInitializationError(_ error: Error) -> Bool {
        let errorMessage = error.localizedDescription.lowercased()
        return errorMessage.contains("corrupted") ||
               errorMessage.contains("invalid") ||
               errorMessage.contains("missing") ||
               errorMessage.contains("not found")
    }
    
    /// Start transcription (must call prepareModel first)
    func startTranscription(recordingStartTime: Date) {
        guard isInitialized else { return }
        transcriptionService.startTranscription(recordingStartTime: recordingStartTime)
    }
    
    /// Stop transcription and process remaining audio
    func stopTranscription() async {
        await transcriptionService.stopTranscription()
        clearBuffers()
        
        // Clear handler to break retain cycle
        transcriptionService.setTranscriptHandler { _ in }
        transcriptionService.setDraftHandler { _, _ in }
    }
    
    deinit {
        logger.debug("Deallocating")
    }
    
    /// Set transcript handler for receiving segments
    func setTranscriptHandler(_ handler: @escaping TranscriptionService.TranscriptHandler) {
        transcriptionService.setTranscriptHandler(handler)
    }
    
    /// Set draft handler for receiving tentative tail text updates
    func setDraftHandler(_ handler: @escaping TranscriptionDraftHandler) {
        transcriptionService.setDraftHandler(handler)
    }
    
    /// Set transcription mode
    func setTranscriptionMode(_ mode: TranscriptionService.TranscriptionMode) {
        transcriptionService.setTranscriptionMode(mode)
    }
    
    /// Get current transcription mode
    var transcriptionMode: TranscriptionService.TranscriptionMode {
        transcriptionService.transcriptionMode
    }
    
    // MARK: - Audio Buffering
    
    /// Buffer system audio while model loads, or forward directly if model ready
    func bufferSystemAudio(_ samples: [Float]) {
        // If model is ready and initialized, forward directly to TranscriptionService
        if modelState.isReady && isInitialized {
            transcriptionService.appendSystemAudio(samples)
            return
        }
        
        // Otherwise buffer while waiting for model
        if bufferStartTime == nil {
            bufferStartTime = Date()
        }
        
        // Check for timeout
        if let startTime = bufferStartTime,
           Date().timeIntervalSince(startTime) > maxBufferDuration {
            // Model loading timeout - clear buffers and notify
            let details = """
                Model loading timed out after \(Int(maxBufferDuration)) seconds.
                Audio was buffered but may be incomplete.
                Recording will continue without transcription.
                """
            onWarning?(.modelLoading, "Model loading timeout", details, false)
            clearBuffers()
            onBufferTimeout?()
            return
        }
        
        // Add to buffer with size limit
        if pendingSystemAudio.count + samples.count <= maxBufferSamples {
            pendingSystemAudio.append(contentsOf: samples)
        } else if samples.count >= maxBufferSamples {
            // Incoming chunk is larger than max buffer - replace with most recent samples
            pendingSystemAudio = Array(samples.suffix(maxBufferSamples))
        } else {
            // Drop oldest samples to make room for new ones
            let overflow = pendingSystemAudio.count + samples.count - maxBufferSamples
            pendingSystemAudio.removeFirst(overflow)
            pendingSystemAudio.append(contentsOf: samples)
        }
    }
    
    /// Buffer microphone audio while model loads, or forward directly if model ready
    func bufferMicrophoneAudio(_ samples: [Float]) {
        // If model is ready and initialized, forward directly to TranscriptionService
        if modelState.isReady && isInitialized {
            transcriptionService.appendMicrophoneAudio(samples)
            return
        }
        
        // Otherwise buffer while waiting for model
        if bufferStartTime == nil {
            bufferStartTime = Date()
        }
        
        // Check for timeout
        if let startTime = bufferStartTime,
           Date().timeIntervalSince(startTime) > maxBufferDuration {
            // Model loading timeout - clear buffers and notify
            // Note: Warning is only sent once (from system audio path)
            clearBuffers()
            onBufferTimeout?()
            return
        }
        
        // Add to buffer with size limit
        if pendingMicAudio.count + samples.count <= maxBufferSamples {
            pendingMicAudio.append(contentsOf: samples)
        } else if samples.count >= maxBufferSamples {
            // Incoming chunk is larger than max buffer - replace with most recent samples
            pendingMicAudio = Array(samples.suffix(maxBufferSamples))
        } else {
            // Drop oldest samples to make room for new ones
            let overflow = pendingMicAudio.count + samples.count - maxBufferSamples
            pendingMicAudio.removeFirst(overflow)
            pendingMicAudio.append(contentsOf: samples)
        }
    }
    
    /// Process buffered audio when model becomes ready
    func processBufferedAudio() {
        guard modelState.isReady, isInitialized else { return }
        
        // Process buffered system audio
        if !pendingSystemAudio.isEmpty {
            transcriptionService.appendSystemAudio(pendingSystemAudio)
            pendingSystemAudio.removeAll()
        }
        
        // Process buffered microphone audio
        if !pendingMicAudio.isEmpty {
            transcriptionService.appendMicrophoneAudio(pendingMicAudio)
            pendingMicAudio.removeAll()
        }
        
        bufferStartTime = nil
    }
    
    /// Clear audio buffers
    private func clearBuffers() {
        pendingSystemAudio.removeAll()
        pendingMicAudio.removeAll()
        bufferStartTime = nil
    }
    
    // MARK: - Auto-Reprocessing (for empty transcripts)
    
    /// Auto-reprocess a meeting once the model becomes ready
    /// Used when recording stopped with empty transcript (model wasn't ready in time)
    func autoReprocessWhenReady(meeting: MeetingHistoryItem) {
        guard let activeModel = modelManager.activeModel else {
            logger.warning("Cannot auto-reprocess: no active model")
            return
        }
        
        logger.info("Auto-reprocessing meeting '\(meeting.title)' when model becomes ready")
        
        // Mark as reprocessing immediately (shows spinner in UI)
        meeting.isReprocessing = true
        
        Task { @MainActor in
            // Wait for model to be ready (may already be ready)
            let modelStateResult = await prepareModel()
            
            if modelStateResult.isReady {
                do {
                    try await reprocessTranscript(for: meeting, using: activeModel)
                    logger.info("Auto-reprocess completed for '\(meeting.title)'")
                } catch {
                    logger.error("Auto-reprocess failed: \(error.localizedDescription)")
                }
            } else {
                logger.warning("Auto-reprocess cancelled: model not ready")
            }
            
            meeting.isReprocessing = false
        }
    }
    
    // MARK: - Reprocessing (for completed meetings)
    
    /// Run second-pass ASR finalization over saved meeting audio segments.
    /// Returns processed transcript blocks sorted by timestamp.
    func runSecondPassASR(
        in directory: URL,
        recordingStartTime: Date,
        preference: PreferencesManager.SecondPassModelPreference,
        liveModel: ModelManager.ModelSize? = nil
    ) async throws -> [TranscriptBlock] {
        guard let selectedModel = resolveSecondPassModel(
            preference: preference,
            liveModel: liveModel
        ) else {
            throw NSError(
                domain: "TranscriptionCoordinator",
                code: 31,
                userInfo: [NSLocalizedDescriptionKey: "No qualifying model available for second-pass ASR"]
            )
        }
        
        guard let modelPath = modelManager.pathForModel(selectedModel),
              modelManager.validateModel(selectedModel)
        else {
            throw NSError(
                domain: "TranscriptionCoordinator",
                code: 32,
                userInfo: [NSLocalizedDescriptionKey: "Selected second-pass model is unavailable or invalid"]
            )
        }
        
        await DiagnosticLogger.shared.log(.stabilizer, "secondPass:start model=\(selectedModel.rawValue)")
        let start = Date()
        
        let tempService = TranscriptionService()
        try await tempService.initialize(modelPath: modelPath)
        tempService.setTranscriptionMode(.postProcessing)
        
        let segmentsToProcess = enumerateAudioSegments(in: directory)
        guard !segmentsToProcess.isEmpty else {
            throw NSError(
                domain: "TranscriptionCoordinator",
                code: 33,
                userInfo: [NSLocalizedDescriptionKey: "No audio files found for second-pass ASR"]
            )
        }
        
        nonisolated(unsafe) var segments: [TranscriptionService.TranscriptSegment] = []
        tempService.setTranscriptHandler { segment in
            segments.append(segment)
        }
        
        for pair in segmentsToProcess {
            try Task.checkCancellation()
            try await tempService.transcribePostProcessing(
                systemAudioURL: pair.systemURL,
                micAudioURL: pair.micURL,
                startTime: recordingStartTime
            )
        }
        
        let processor = TranscriptProcessor()
        for segment in segments.sorted(by: { $0.timestamp < $1.timestamp }) {
            processor.processSegment(segment)
        }
        processor.finalize()
        
        let elapsed = Date().timeIntervalSince(start)
        await DiagnosticLogger.shared.log(
            .stabilizer,
            "secondPass:done model=\(selectedModel.rawValue) blocks=\(processor.blocks.count) segments=\(segments.count) duration=\(String(format: "%.2f", elapsed))s"
        )
        return processor.blocks
    }

    private func resolveSecondPassModel(
        preference: PreferencesManager.SecondPassModelPreference,
        liveModel: ModelManager.ModelSize?
    ) -> ModelManager.ModelSize? {
        let effectiveLiveModel = liveModel ?? modelManager.activeModel

        func isReady(_ model: ModelManager.ModelSize) -> Bool {
            modelManager.downloadState(for: model) == .completed &&
                modelManager.pathForModel(model) != nil &&
                modelManager.validateModel(model)
        }
        
        let ranked: [ModelManager.ModelSize] = [.large, .largeTurbo, .medium, .small]
        let bestAvailable = ranked.first(where: isReady)
        
        switch preference {
        case .bestAvailable:
            return bestAvailable
        case .sameAsLive:
            guard let effectiveLiveModel, isReady(effectiveLiveModel) else { return nil }
            return effectiveLiveModel
        case .bestAvailableNoDowngrade:
            guard let effectiveLiveModel else { return bestAvailable }
            guard let candidate = bestAvailable else { return nil }
            let rank: [ModelManager.ModelSize: Int] = [.large: 0, .largeTurbo: 1, .medium: 2, .small: 3]
            guard let liveRank = rank[effectiveLiveModel], let candidateRank = rank[candidate], candidateRank <= liveRank else {
                return nil
            }
            return candidate
        case .specific:
            guard let raw = UserDefaults.standard.string(forKey: AppStorageKeys.secondPassSpecificModel),
                  let model = ModelManager.ModelSize(rawValue: raw),
                  isReady(model) else {
                return nil
            }
            return model
        }
    }

    private func enumerateAudioSegments(in directory: URL) -> [(systemURL: URL?, micURL: URL?)] {
        let fm = FileManager.default
        var pairs: [(Int, URL?, URL?)] = []
        
        let primarySystem = directory.appendingPathComponent("audio.caf")
        let primaryMic = directory.appendingPathComponent("microphone.caf")
        if fm.fileExists(atPath: primarySystem.path) || fm.fileExists(atPath: primaryMic.path) {
            pairs.append((1, fm.fileExists(atPath: primarySystem.path) ? primarySystem : nil, fm.fileExists(atPath: primaryMic.path) ? primaryMic : nil))
        }
        
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return pairs.map { ($0.1, $0.2) }
        }
        
        for file in contents {
            let name = file.lastPathComponent
            if let index = parseSegmentIndex(from: name, prefix: "audio_", suffix: ".caf") {
                while !pairs.contains(where: { $0.0 == index }) {
                    pairs.append((index, nil, nil))
                }
                if let pairIndex = pairs.firstIndex(where: { $0.0 == index }) {
                    pairs[pairIndex].1 = file
                }
            } else if let index = parseSegmentIndex(from: name, prefix: "microphone_", suffix: ".caf") {
                while !pairs.contains(where: { $0.0 == index }) {
                    pairs.append((index, nil, nil))
                }
                if let pairIndex = pairs.firstIndex(where: { $0.0 == index }) {
                    pairs[pairIndex].2 = file
                }
            }
        }
        
        return pairs
            .sorted(by: { $0.0 < $1.0 })
            .map { ($0.1, $0.2) }
            .filter { $0.0 != nil || $0.1 != nil }
    }
    
    private func parseSegmentIndex(from name: String, prefix: String, suffix: String) -> Int? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        return Int(name[start..<end])
    }
    
    /// Reprocess a completed meeting's audio with a different model
    ///
    /// This function transcribes existing audio files using a specified WhisperKit model,
    /// converts the results to TranscriptBlocks (chunked to ~50 words max), updates the
    /// meeting object, and saves the transcript to disk.
    ///
    /// - Parameters:
    ///   - meeting: The meeting to reprocess
    ///   - modelSize: The model size to use
    ///   - progressHandler: Optional progress callback
    ///
    /// - Important: This function MUST:
    ///   1. Collect transcription segments from the handler
    ///   2. Convert segments to TranscriptBlocks
    ///   3. Update meeting.transcriptBlocks and meeting.transcript
    ///   4. Save the transcript to disk via FileOutputService
    ///   Failure to complete all steps will result in the UI not updating.
    func reprocessTranscript(
        for meeting: MeetingHistoryItem,
        using modelSize: ModelManager.ModelSize,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws {
        // Get model path
        guard let modelPath = modelManager.pathForModel(modelSize) else {
            throw NSError(domain: "TranscriptionCoordinator", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Model not found: \(modelSize.rawValue)"])
        }
        
        // Validate model
        guard modelManager.validateModel(modelSize) else {
            throw NSError(domain: "TranscriptionCoordinator", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Model is corrupted: \(modelSize.rawValue)"])
        }
        
        // Log reprocess start
        Task { await DiagnosticLogger.shared.log(.transcription,
            "Reprocess: model=\(modelSize.rawValue)") }
        
        // Initialize transcription service with selected model
        let tempService = TranscriptionService()
        try await tempService.initialize(modelPath: modelPath)
        tempService.setTranscriptionMode(.postProcessing)
        
        // Get audio file URLs
        let systemAudioURL = meeting.directory.appendingPathComponent("audio.caf")
        let micAudioURL = meeting.directory.appendingPathComponent("microphone.caf")
        let systemExists = FileManager.default.fileExists(atPath: systemAudioURL.path)
        let micExists = FileManager.default.fileExists(atPath: micAudioURL.path)
        
        // Log audio file availability
        Task { await DiagnosticLogger.shared.log(.transcription,
            "Audio files: system=\(systemExists), mic=\(micExists)") }
        
        // Transcribe - use nonisolated(unsafe) since we're on MainActor and handler runs synchronously
        nonisolated(unsafe) var segments: [TranscriptionService.TranscriptSegment] = []
        tempService.setTranscriptHandler { segment in
            segments.append(segment)
        }
        
        try await tempService.transcribePostProcessing(
            systemAudioURL: systemExists ? systemAudioURL : nil,
            micAudioURL: micExists ? micAudioURL : nil,
            startTime: meeting.date
        )
        
        // Log reprocess completion
        Task { await DiagnosticLogger.shared.log(.transcription,
            "Reprocess done: segments=\(segments.count)") }
        
        // Use TranscriptProcessor to filter artifacts (e.g., [BLANK_AUDIO], hallucinations)
        // and merge segments into blocks with word limits
        let processor = TranscriptProcessor()
        for segment in segments {
            processor.processSegment(segment)
        }
        processor.finalize()
        let blocks = processor.blocks
        
        // Log processor output
        Task { await DiagnosticLogger.shared.log(.transcription,
            "Processor: blocks=\(blocks.count)") }
        
        // IMPORTANT: Update meeting AND save to disk - both are required for UI to reflect changes
        if !blocks.isEmpty {
            meeting.transcriptBlocks = blocks
            meeting.transcript = blocks.map { $0.text }.joined(separator: "\n\n")
            
            // Save transcript to disk
            let fileOutput = FileOutputService()
            try fileOutput.saveTranscriptBlocks(blocks, title: meeting.title, date: meeting.date, to: meeting.directory)
            
            // Notify that meeting was updated (for export)
            onMeetingUpdated?(meeting)
        }
        
        progressHandler?(1.0)
    }
    
    // MARK: - Live Refinement
    
    /// Queue a segment for live refinement
    /// Called after a segment is created during recording
    func queueSegmentForLiveRefinement(_ segment: TranscriptSegment, in meeting: MeetingHistoryItem) {
        guard liveRefinementEnabled else { return }
        guard let coordinator = refinementCoordinator else { return }
        guard coordinator.canRefineTranscripts else { return }
        
        // Check queue depth - skip if falling behind
        guard liveRefinementQueue.count < maxRefinementQueueDepth else {
            logger.warning(
                """
                Live refinement queue full (\(self.liveRefinementQueue.count)), \
                skipping segment \(segment.segmentNumber)
                """
            )
            return
        }
        
        // Add to queue
        liveRefinementQueue.append(segment)
        
        // Start processing if not already running
        if currentRefinementTask == nil {
            currentRefinementTask = Task { @MainActor in
                await processLiveRefinementQueue(meeting: meeting)
            }
        }
    }
    
    /// Process the live refinement queue in the background
    private func processLiveRefinementQueue(meeting: MeetingHistoryItem) async {
        while !liveRefinementQueue.isEmpty {
            // Get next segment to refine
            let segment = liveRefinementQueue.removeFirst()
            
            // Refine with background priority (detached to actually run in background)
            guard let coordinator = refinementCoordinator else { continue }
            
            // Use Task.detached to ensure background priority is respected
            // Don't await here to allow concurrent processing
            Task.detached(priority: .background) {
                await coordinator.refineSegment(segment, in: meeting)
            }
        }
        
        // Clear task reference when done
        currentRefinementTask = nil
    }
    
    /// Stop live refinement processing (when recording stops)
    func stopLiveRefinement() {
        currentRefinementTask?.cancel()
        currentRefinementTask = nil
        liveRefinementQueue.removeAll()
    }
}
