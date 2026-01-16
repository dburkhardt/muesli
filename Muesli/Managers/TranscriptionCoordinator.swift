import Foundation

// #region agent log
fileprivate extension String {
    func appendToDebugLogFile(atPath path: String) {
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            if let data = self.data(using: .utf8) {
                handle.write(data)
            }
        } else {
            try? self.write(toFile: path, atomically: false, encoding: .utf8)
        }
    }
}
// #endregion

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
        // #region agent log
        let logPath = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
        let logData = try? JSONSerialization.data(withJSONObject: ["sessionId":"debug-session","runId":"initial","hypothesisId":"A","location":"TranscriptionCoordinator.swift:bufferSystemAudio","message":"bufferSystemAudio called","data":["sampleCount":samples.count,"modelStateReady":modelState.isReady,"isInitialized":isInitialized,"pendingCount":pendingSystemAudio.count],"timestamp":Date().timeIntervalSince1970*1000])
        if let data = logData, let json = String(data: data, encoding: .utf8) { try? (json + "\n").appendToDebugLogFile(atPath: logPath) }
        // #endregion
        
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
        } else {
            // Buffer full - drop oldest samples
            let overflow = pendingSystemAudio.count + samples.count - maxBufferSamples
            if overflow < pendingSystemAudio.count {
                pendingSystemAudio.removeFirst(overflow)
            }
            pendingSystemAudio.append(contentsOf: samples)
        }
    }
    
    /// Buffer microphone audio while model loads, or forward directly if model ready
    func bufferMicrophoneAudio(_ samples: [Float]) {
        // #region agent log
        let logPath = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
        let logData = try? JSONSerialization.data(withJSONObject: ["sessionId":"debug-session","runId":"initial","hypothesisId":"A","location":"TranscriptionCoordinator.swift:bufferMicrophoneAudio","message":"bufferMicrophoneAudio called","data":["sampleCount":samples.count,"modelStateReady":modelState.isReady,"isInitialized":isInitialized,"pendingCount":pendingMicAudio.count],"timestamp":Date().timeIntervalSince1970*1000])
        if let data = logData, let json = String(data: data, encoding: .utf8) { try? (json + "\n").appendToDebugLogFile(atPath: logPath) }
        // #endregion
        
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
        } else {
            // Buffer full - drop oldest samples
            let overflow = pendingMicAudio.count + samples.count - maxBufferSamples
            if overflow < pendingMicAudio.count {
                pendingMicAudio.removeFirst(overflow)
            }
            pendingMicAudio.append(contentsOf: samples)
        }
    }
    
    /// Process buffered audio when model becomes ready
    func processBufferedAudio() {
        // #region agent log
        let logPath = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
        let logData = try? JSONSerialization.data(withJSONObject: ["sessionId":"debug-session","runId":"initial","hypothesisId":"A,C","location":"TranscriptionCoordinator.swift:processBufferedAudio","message":"processBufferedAudio called","data":["modelStateReady":modelState.isReady,"isInitialized":isInitialized,"pendingSystemCount":pendingSystemAudio.count,"pendingMicCount":pendingMicAudio.count],"timestamp":Date().timeIntervalSince1970*1000])
        if let data = logData, let json = String(data: data, encoding: .utf8) { try? (json + "\n").appendToDebugLogFile(atPath: logPath) }
        // #endregion
        
        guard modelState.isReady, isInitialized else { return }
        
        // Process buffered system audio
        if !pendingSystemAudio.isEmpty {
            // #region agent log
            let logData2 = try? JSONSerialization.data(withJSONObject: ["sessionId":"debug-session","runId":"initial","hypothesisId":"A","location":"TranscriptionCoordinator.swift:processBufferedAudio","message":"Forwarding system audio to TranscriptionService","data":["count":pendingSystemAudio.count],"timestamp":Date().timeIntervalSince1970*1000])
            if let data = logData2, let json = String(data: data, encoding: .utf8) { try? (json + "\n").appendToDebugLogFile(atPath: logPath) }
            // #endregion
            transcriptionService.appendSystemAudio(pendingSystemAudio)
            pendingSystemAudio.removeAll()
        }
        
        // Process buffered microphone audio
        if !pendingMicAudio.isEmpty {
            // #region agent log
            let logData3 = try? JSONSerialization.data(withJSONObject: ["sessionId":"debug-session","runId":"initial","hypothesisId":"A","location":"TranscriptionCoordinator.swift:processBufferedAudio","message":"Forwarding mic audio to TranscriptionService","data":["count":pendingMicAudio.count],"timestamp":Date().timeIntervalSince1970*1000])
            if let data = logData3, let json = String(data: data, encoding: .utf8) { try? (json + "\n").appendToDebugLogFile(atPath: logPath) }
            // #endregion
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
    /// - Parameters:
    ///   - meeting: The meeting to reprocess
    ///   - modelSize: The model size to use
    ///   - progressHandler: Optional progress callback
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
        
        // Transcribe - use nonisolated(unsafe) since we're on MainActor and handler runs synchronously
        nonisolated(unsafe) var segments: [TranscriptionService.TranscriptSegment] = []
        tempService.setTranscriptHandler { segment in
            segments.append(segment)
        }
        
        try await tempService.transcribePostProcessing(
            systemAudioURL: FileManager.default.fileExists(atPath: systemAudioURL.path) ? systemAudioURL : nil,
            micAudioURL: FileManager.default.fileExists(atPath: micAudioURL.path) ? micAudioURL : nil,
            startTime: meeting.date
        )
        
        // TODO: Update meeting with new transcript segments
        // This will be implemented when we connect to the UI
        _ = segments  // Use collected segments
        
        progressHandler?(1.0)
    }
}
