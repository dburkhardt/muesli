import Foundation


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
    
    private let transcriptionService: any TranscriptionServiceProtocol
    private let modelManager: any ModelManagerProtocol
    
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
    
    /// Maximum buffering duration (30 seconds) before timeout
    private let maxBufferDuration: TimeInterval = AudioConfiguration.bufferTimeoutSeconds
    
    /// Maximum retries for model loading to prevent infinite recursion
    private let maxModelRetries: Int = AudioConfiguration.maxModelRetries
    
    /// Current retry count
    private var retriesRemaining: Int = 3
    
    /// Callback when buffer timeout occurs
    var onBufferTimeout: (() -> Void)?
    
    /// Callback when model switches due to fallback (from, to, reason)
    var onModelSwitched: ((ModelManager.ModelSize, ModelManager.ModelSize, Error) -> Void)?
    
    // MARK: - Initialization
    
    init(transcriptionService: any TranscriptionServiceProtocol, modelManager: any ModelManagerProtocol) {
        self.transcriptionService = transcriptionService
        self.modelManager = modelManager
    }
    
    // MARK: - Model Lifecycle
    
    /// Reset per-recording state so new sessions can retry model loading
    func resetForNewRecording() {
        retriesRemaining = maxModelRetries
        if case .failed = modelState {
            modelState = .notAvailable
        }
        clearBuffers()
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
        
        // Validate model
        guard modelManager.validateModel(activeModel),
              let modelPath = modelManager.pathForModel(activeModel) else {
            
            // Only mark corrupted on validation errors
            modelManager.markModelCorrupted(activeModel)
            
            // Try fallback
            if let fallback = modelManager.getFirstValidModel() {
                modelManager.setActiveModel(fallback)
                
                // Notify user of model switch
                let error = MuesliError.modelCorrupted(modelName: "\(activeModel)")
                onModelSwitched?(activeModel, fallback, error)
                
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
        
        do {
            try await transcriptionService.initialize(modelPath: modelPath)
            isInitialized = true
            modelState = .ready
            // Flush any buffered audio collected during loading
            processBufferedAudio()
            // Reset retry count on success
            retriesRemaining = maxModelRetries
            return .ready
        } catch {
            modelState = .failed(error)
            
            // Only mark corrupted on specific initialization errors, not temporary failures
            if isInitializationError(error) {
                modelManager.markModelCorrupted(activeModel)
            }
            
            if let fallback = modelManager.getFirstValidModel() {
                modelManager.setActiveModel(fallback)
                isInitialized = false
                
                // Notify user of model switch
                onModelSwitched?(activeModel, fallback, error)
                
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
    }
    
    deinit {
        print("[TranscriptionCoordinator] Deallocating")
    }
    
    /// Set transcript handler for receiving segments
    func setTranscriptHandler(_ handler: @escaping TranscriptionService.TranscriptHandler) {
        transcriptionService.setTranscriptHandler(handler)
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
    
    // MARK: - Reprocessing (for completed meetings)
    
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
        
        // Initialize transcription service with selected model
        let tempService = TranscriptionService()
        try await tempService.initialize(modelPath: modelPath)
        tempService.setTranscriptionMode(.postProcessing)
        
        // Get audio file URLs
        let systemAudioURL = meeting.directory.appendingPathComponent("audio.caf")
        let micAudioURL = meeting.directory.appendingPathComponent("microphone.caf")
        let systemExists = FileManager.default.fileExists(atPath: systemAudioURL.path)
        let micExists = FileManager.default.fileExists(atPath: micAudioURL.path)
        
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
        
        // Convert segments to TranscriptBlocks with ~50 word limit per block
        // This ensures readable chunk sizes in the UI
        let maxWordsPerBlock = 50
        var blocks: [TranscriptBlock] = []
        
        for segment in segments {
            let speaker: TranscriptBlock.Speaker = segment.speaker == .me ? .me : .them
            let words = segment.text.split(separator: " ")
            
            // Split into chunks of maxWordsPerBlock
            var wordIndex = 0
            while wordIndex < words.count {
                let endIndex = min(wordIndex + maxWordsPerBlock, words.count)
                let chunkWords = words[wordIndex..<endIndex]
                let chunkText = chunkWords.joined(separator: " ")
                
                // Calculate approximate timestamp offset within segment
                let progressInSegment = Double(wordIndex) / Double(max(words.count, 1))
                let chunkTimestamp = segment.timestamp + (progressInSegment * 5.0) // Approximate 5 sec per segment
                
                let block = TranscriptBlock(
                    speaker: speaker,
                    text: chunkText,
                    startTimestamp: chunkTimestamp,
                    endTimestamp: chunkTimestamp + 5.0
                )
                blocks.append(block)
                
                wordIndex = endIndex
            }
        }
        
        // IMPORTANT: Update meeting AND save to disk - both are required for UI to reflect changes
        if !blocks.isEmpty {
            meeting.transcriptBlocks = blocks
            meeting.transcript = blocks.map { $0.text }.joined(separator: "\n\n")
            
            // Save transcript to disk
            let fileOutput = FileOutputService()
            try fileOutput.saveTranscriptBlocks(blocks, title: meeting.title, date: meeting.date, to: meeting.directory)
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
            print("[TranscriptionCoordinator] Live refinement queue full (\(liveRefinementQueue.count)), skipping segment \(segment.segmentNumber)")
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
            
            // Refine with background priority
            guard let coordinator = refinementCoordinator else { continue }
            
            await Task(priority: .background) {
                await coordinator.refineSegment(segment, in: meeting)
            }.value
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
