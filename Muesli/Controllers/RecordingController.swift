import AVFoundation
import CoreMedia
import Foundation
import os.lock
import os.log
import SwiftUI

/// Controller responsible for recording lifecycle management
/// Extracted from MuesliViewModel to improve separation of concerns
@Observable
@MainActor
final class RecordingController {
    // MARK: - Logging
    
    private let logger = Logger(subsystem: "com.muesli.app", category: "RecordingController")
    
    // MARK: - Dependencies
    
    private let audioCaptureService: any AudioCaptureServiceProtocol
    private let fileOutputService: FileOutputService
    private let transcriptionService: TranscriptionService
    private let transcriptionCoordinator: TranscriptionCoordinator
    private let preferencesManager: PreferencesManager
    private let microphoneManager: MicrophoneManager
    private let exportService: ExportService
    
    /// Warning manager for propagating non-fatal errors to UI
    let warningManager: WarningManager
    
    // MARK: - State
    
    /// The currently recording session (only one can record at a time)
    private(set) var activeSession: RecordingSession?
    
    /// Whether to show the model error alert
    var showModelErrorAlert: Bool = false
    
    /// Session waiting for user response to model error
    var sessionPendingModelDecision: RecordingSession?
    
    /// Whether to show the meeting title prompt sheet
    var showTitlePromptSheet: Bool = false
    
    /// Session pending stop (waiting for title input)
    var pendingStopSession: RecordingSession?
    
    /// Background second-pass finalization task for the latest completed session.
    nonisolated(unsafe) private var secondPassFinalizationTask: Task<Void, Never>?

    /// Deterministic skip reasons for automatic post-stop finalization.
    enum AutomaticFinalizationSkipReason: String, Equatable {
        case noAudioFiles
        case preferenceDisabled
        case recordingTooShort
    }

    /// Pure decision output for second-pass eligibility.
    struct AutomaticFinalizationDecision: Equatable {
        let shouldLaunchSecondPass: Bool
        let skipReason: AutomaticFinalizationSkipReason?
    }

    /// Timing diagnostics for stop-flow phases.
    private struct StopPhaseTiming: Sendable {
        var stopCaptureMs: Int = 0
        var stopTranscriptionMs: Int = 0
        var stopWritingMs: Int = 0
        var totalMs: Int = 0
    }
    
    // MARK: - Audio Level Throttling
    
    /// Last time microphone level was updated (for throttling UI updates)
    private var lastMicLevelUpdate = Date.distantPast
    
    /// Last time system audio level was updated (for throttling UI updates)
    private var lastSystemLevelUpdate = Date.distantPast
    
    /// Minimum interval between audio level UI updates (~30fps)
    private let levelUpdateInterval: TimeInterval = AudioConfiguration.levelUpdateInterval
    
    /// Consecutive audio processing error counter
    private var audioErrorCounter: Int = 0
    
    /// Maximum consecutive audio errors before stopping recording
    private let maxConsecutiveAudioErrors: Int = AudioConfiguration.maxConsecutiveAudioErrors
    
    // MARK: - Thread-safe Mute State
    
    /// Microphone mute state (for synchronous access from audio callback)
    /// Uses OSAllocatedUnfairLock for proper thread-safe access
    private let isMicrophoneMutedLock = OSAllocatedUnfairLock(initialState: false)
    
    /// Thread-safe getter for audio callbacks (nonisolated)
    nonisolated var isMicrophoneMutedSafe: Bool {
        isMicrophoneMutedLock.withLock { $0 }
    }
    
    // MARK: - Callbacks
    
    /// Called when a new recording session starts (for ViewModel state sync)
    var onSessionStarted: ((RecordingSession) -> Void)?
    
    /// Called when active session changes (for history manager updates)
    var onSessionCompleted: ((RecordingSession, URL?) -> Void)?
    
    /// Called when meeting history should be refreshed
    var onRefreshHistory: (() -> Void)?
    
    /// Called when the selected meeting should change
    var onSelectedMeetingChanged: ((MeetingHistoryItem?) -> Void)?
    
    /// Called when auto-reprocessing should run on a completed meeting directory.
    /// The ViewModel must resolve the directory to its canonical MeetingHistoryItem
    /// from the history list (not a local throwaway copy) so observable state
    /// changes propagate to the UI.
    var onAutoReprocessRequested: ((URL) -> Void)?
    
    /// Called when auto-refinement should run on a completed meeting directory.
    /// Same canonical-resolution requirement as onAutoReprocessRequested.
    var onAutoRefineRequested: ((URL) -> Void)?
    
    /// Called when a permission error is detected during recording start.
    /// Parameters: (missingScreen: Bool, missingMic: Bool)
    var onPermissionRecoveryNeeded: ((Bool, Bool) -> Void)?
    
    // MARK: - Initialization
    
    init(
        audioCaptureService: any AudioCaptureServiceProtocol,
        fileOutputService: FileOutputService,
        transcriptionService: TranscriptionService,
        transcriptionCoordinator: TranscriptionCoordinator,
        preferencesManager: PreferencesManager,
        microphoneManager: MicrophoneManager,
        exportService: ExportService,
        warningManager: WarningManager = WarningManager()
    ) {
        self.audioCaptureService = audioCaptureService
        self.fileOutputService = fileOutputService
        self.transcriptionService = transcriptionService
        self.transcriptionCoordinator = transcriptionCoordinator
        self.preferencesManager = preferencesManager
        self.microphoneManager = microphoneManager
        self.exportService = exportService
        self.warningManager = warningManager
        
        // Wire up service warning callbacks
        wireWarningCallbacks()
        
        // Note: Audio buffer handler is set up in ensureAudioHandlersConfigured() before each recording
    }
    
    /// Wire up warning callbacks from all services to the warning manager
    private func wireWarningCallbacks() {
        // FileOutputService warnings
        fileOutputService.onWarning = { [weak self] message, details in
            Task { @MainActor in
                self?.warningManager.addWarning(.fileOutput, message: message, details: details, canRetry: false)
            }
        }
        
        // TranscriptionCoordinator warnings
        transcriptionCoordinator.onWarning = { [weak self] category, message, details, canRetry in
            Task { @MainActor in
                self?.warningManager.addWarning(category, message: message, details: details, canRetry: canRetry)
            }
        }
        
        // TranscriptionCoordinator warning dismissal (auto-dismiss when model ready)
        transcriptionCoordinator.onWarningDismissed = { [weak self] category in
            Task { @MainActor in
                self?.warningManager.dismissWarnings(for: category)
            }
        }
        
        // ExportService warnings
        exportService.onWarning = { [weak self] message, details in
            Task { @MainActor in
                self?.warningManager.addWarning(.export, message: message, details: details, canRetry: false)
            }
        }
        
        // TranscriptionService warnings (wired at start of recording)
        transcriptionService.setWarningHandler { [weak self] message, details in
            Task { @MainActor in
                self?.warningManager.addWarning(.transcription, message: message, details: details, canRetry: false)
            }
        }
    }
    
    deinit {
        secondPassFinalizationTask?.cancel()
        logger.debug("Deallocating")
    }
    
    // MARK: - Audio Buffer Handler Setup
    
    /// Ensures audio handlers are configured before starting capture
    /// Must be called (and awaited) before audioCaptureService.startCapture()
    private func ensureAudioHandlersConfigured() async {
        let fileService = self.fileOutputService
        let transcriptionCoordinator = self.transcriptionCoordinator
        let audioCaptureServiceRef = self.audioCaptureService

        // Capture locks directly to avoid @MainActor isolation in callback
        let muteLock = self.isMicrophoneMutedLock
        let ingestionQueue = DispatchQueue(label: "com.muesli.app.transcription.ingestion", qos: .userInitiated)
        let micBatchBuffer = OSAllocatedUnfairLock(initialState: [Float]())
        let renderBatchBuffer = OSAllocatedUnfairLock(initialState: [Float]())
        let batchThreshold = 9600  // 200ms at 48kHz

        await audioCaptureServiceRef.setBufferHandler { [weak self] buffer, type in
                // Wrap entire handler in error handling for graceful degradation
                do {
                    switch type {
                    case .system:
                        try RecordingController.handleSystemAudioBuffer(
                            buffer,
                            fileService: fileService
                        )

                    case .microphone:
                        try RecordingController.handleMicrophoneAudioBuffer(
                            buffer,
                            fileService: fileService
                        )
                    case .rawMicrophone:
                        try RecordingController.handleRawMicrophoneAudioBuffer(
                            buffer,
                            fileService: fileService
                        )
                    }

                    // Reset error counter on success
                    Task { @MainActor in
                        self?.audioErrorCounter = 0
                    }
                } catch {
                    // Log error but continue processing
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.logger.error("Audio buffer processing error: \(error)")
                        self.audioErrorCounter += 1

                        // If too many consecutive errors, stop recording gracefully
                        if self.audioErrorCounter > self.maxConsecutiveAudioErrors {
                            self.logger.error(
                                "Too many consecutive audio errors (\(self.audioErrorCounter)), stopping recording"
                            )

                            if let session = self.activeSession {
                                session.interruptionReason = "Audio processing error"
                                self.handleCaptureInterrupted(error: error)
                            }
                        }
                    }
                }
            }

            // Set up stream interruption handler
            await audioCaptureServiceRef.setInterruptedHandler { [weak self] error in
                Task { @MainActor in
                    self?.handleCaptureInterrupted(error: error)
                }
            }

        // Set up audio level handler
        await audioCaptureServiceRef.setLevelHandler { [weak self] level, type in
            Task { @MainActor in
                self?.updateAudioLevel(level, type: type)
            }
        }

        // Set up audio warning handler (for mic failures, system audio issues, etc.)
        await audioCaptureServiceRef.setWarningHandler { [weak self] category, message, details, canRetry in
            Task { @MainActor in
                self?.warningManager.addWarning(category, message: message, details: details, canRetry: canRetry)
            }
        }

        // Set up processed mic handler (48kHz mono -> batched -> 16kHz -> transcription)
        await audioCaptureServiceRef.setProcessedMicHandler { [weak self] frame in
            ingestionQueue.async {
                guard self != nil else { return }
                let isMicMuted = muteLock.withLock { $0 }
                guard !isMicMuted else { return }

                let batch: [Float]? = micBatchBuffer.withLock { buffer in
                    buffer.append(contentsOf: frame.samples)
                    guard buffer.count >= batchThreshold else { return nil }
                    let output = buffer
                    buffer.removeAll(keepingCapacity: true)
                    return output
                }

                guard let batch else { return }
                let samples16k = TranscriptionService.resampleToWhisperFormat(
                    batch,
                    sourceSampleRate: Double(frame.sampleRate),
                    sourceChannels: 1
                )

                Task { @MainActor in
                    guard self != nil else { return }
                    transcriptionCoordinator.bufferMicrophoneAudio(samples16k)
                }
            }
        }

        // Set up processed render handler (48kHz mono -> batched -> 16kHz -> transcription)
        await audioCaptureServiceRef.setProcessedRenderHandler { [weak self] frame in
            ingestionQueue.async {
                guard self != nil else { return }

                let batch: [Float]? = renderBatchBuffer.withLock { buffer in
                    buffer.append(contentsOf: frame.samples)
                    guard buffer.count >= batchThreshold else { return nil }
                    let output = buffer
                    buffer.removeAll(keepingCapacity: true)
                    return output
                }

                guard let batch else { return }
                let samples16k = TranscriptionService.resampleToWhisperFormat(
                    batch,
                    sourceSampleRate: Double(frame.sampleRate),
                    sourceChannels: 1
                )

                Task { @MainActor in
                    guard self != nil else { return }
                    transcriptionCoordinator.bufferSystemAudio(samples16k)
                }
            }
        }
    }

    // MARK: - Audio Buffer Processing Helpers

    /// Process system audio buffer — file output only
    /// Transcription is now handled by the AEC-processed audio callback from TapAudioCaptureService
    private static nonisolated func handleSystemAudioBuffer(
        _ buffer: CMSampleBuffer,
        fileService: FileOutputService
    ) throws {
        fileService.appendAudioBuffer(buffer, type: .system)
    }
    
    /// Process AEC-processed microphone audio buffer — file output only
    /// Transcription is handled by the AEC-processed audio callback from TapAudioCaptureService
    private static nonisolated func handleMicrophoneAudioBuffer(
        _ buffer: CMSampleBuffer,
        fileService: FileOutputService
    ) throws {
        fileService.appendAudioBuffer(buffer, type: .microphone)
    }

    /// Process raw (pre-AEC) microphone audio buffer — file output only, when preference enabled
    private static nonisolated func handleRawMicrophoneAudioBuffer(
        _ buffer: CMSampleBuffer,
        fileService: FileOutputService
    ) throws {
        fileService.appendAudioBuffer(buffer, type: .rawMicrophone)
    }

    // MARK: - Session Management
    
    /// Create a new recording session
    func createSession() -> RecordingSession {
        return RecordingSession()
    }
    
    /// Update audio level for the active session (throttled to ~30fps)
    private func updateAudioLevel(_ level: Float, type: AudioStreamType) {
        guard let session = activeSession else { return }
        let now = Date()
        
        switch type {
        case .microphone:
            guard now.timeIntervalSince(lastMicLevelUpdate) >= levelUpdateInterval else { return }
            lastMicLevelUpdate = now
            session.microphoneLevel = level
        case .system:
            guard now.timeIntervalSince(lastSystemLevelUpdate) >= levelUpdateInterval else { return }
            lastSystemLevelUpdate = now
            session.systemAudioLevel = level
        case .rawMicrophone:
            break
        }
    }
    
    // MARK: - Recording Actions
    
    /// Quick start recording with all system audio (no app selection needed)
    func quickStartRecording() {
        guard activeSession == nil else {
            return  // Already recording
        }
        
        // Create a new session (captures all system audio)
        let session = createSession()
        
        // Use saved microphone preference, or fall back to default if none set
        if microphoneManager.selectedDeviceID == nil {
            if let defaultMic = microphoneManager.currentDefaultDevice {
                microphoneManager.setSelectedDeviceID(defaultMic.id)
            }
        }
        
        // Start recording
        startRecording(for: session)
    }
    
    /// Start recording for a session
    func startRecording(for session: RecordingSession) {
        // Only one session can record at a time
        guard activeSession == nil else {
            session.showError(.alreadyRecording)
            return
        }
        
        // Set activeSession immediately so UI shows recording view right away
        activeSession = session
        let mutedState = session.isMicrophoneMuted
        isMicrophoneMutedLock.withLock { $0 = mutedState }
        
        // Mark as initializing (loading model)
        session.isInitializing = true
        
        // Notify ViewModel that session started
        onSessionStarted?(session)
        
        Task {
            await startRecordingAsync(for: session)
        }
    }
    
    private func startRecordingAsync(for session: RecordingSession) async {
        // Clear any previous warnings at start of new recording
        warningManager.clearAll()
        do {
            // Start file output FIRST
            let saveRaw = preferencesManager.saveRawMicrophoneAudio
            session.outputDirectory = try fileOutputService.startWriting(
                saveRawMicrophone: saveRaw
            )
            
            let aecOn = preferencesManager.echoCancellationEnabledForAudioCallback
            logger.info("MIC_FILE_OUTPUT: aecEnabled=\(aecOn), saveRaw=\(saveRaw), routing=.microphone from processed path")
            Task {
                await DiagnosticLogger.shared.log(.app,
                    "MIC_FILE_OUTPUT: aecEnabled=\(aecOn), saveRaw=\(saveRaw), routing=.microphone from processed path")
            }
            
            // Configure microphone preference before starting capture
            // Pass selected mic device to audio capture service for AVAudioEngine capture
            let selectedMicID = microphoneManager.selectedDeviceID
            await audioCaptureService.setMicrophoneDevice(selectedMicID)

            // CRITICAL: Ensure audio handlers are configured BEFORE starting capture
            // This fixes the race condition where handlers weren't set when capture started
            
            await ensureAudioHandlersConfigured()
            
            // Start audio capture IMMEDIATELY (before model check)
            try await audioCaptureService.startCapture()
            
            // Audio is now flowing and being saved to disk
            session.recordingStartTime = Date()
            session.state = .recording
            session.startDisplayTimer()

            // Mark initialization as completing audio setup
            session.isInitializing = false
            
            // NOW try transcription (async, non-blocking)
            Task {
                await prepareTranscriptionAsync(for: session)
            }
        } catch let error as AudioCaptureError {
            handleCaptureError(error, for: session)
        } catch {
            handleGenericError(error, for: session)
        }
    }
    
    private func prepareTranscriptionAsync(for session: RecordingSession) async {
        // Set modelLoading indicator
        session.isModelLoading = true
        
        transcriptionCoordinator.resetForNewRecording()
        let modelState = await transcriptionCoordinator.prepareModel()
        switch modelState {
        case .notAvailable:
            session.isModelLoading = false
            session.isRecordingOnly = true
            session.effectiveLiveModel = nil
            // Continue recording without transcription
            
        case .loading:
            // Keep indicator showing, coordinator buffers audio
            break
            
        case .ready:
            session.isModelLoading = false
            session.effectiveLiveModel = transcriptionCoordinator.effectiveLiveModelForSession
            transcriptionCoordinator.setTranscriptHandler { [weak session] segment in
                Task { @MainActor in
                    session?.appendTranscriptSegment(segment)
                }
            }
            transcriptionCoordinator.setDraftHandler { [weak session] draftText, speaker in
                Task { @MainActor in
                    guard let session = session else { return }
                    session.updateLiveDraft(
                        draftText,
                        speaker: speaker == .me ? .me : .them
                    )
                }
            }
            transcriptionCoordinator.startTranscription(recordingStartTime: session.recordingStartTime ?? Date())
            
        case .failed(let error):
            session.isModelLoading = false
            session.isRecordingOnly = true
            session.effectiveLiveModel = nil
            // Log error but continue recording audio
            logger.error("Model loading failed: \(error), continuing audio-only recording")
            
            // Propagate warning to UI
            let details = """
                Transcription model failed to load.
                Error: \(error.localizedDescription)
                
                Recording will continue without transcription.
                You can re-transcribe later from the saved audio files.
                """
            warningManager.addWarning(.modelLoading, message: "Transcription unavailable", details: details, canRetry: false)
        }
    }
    
    private func handleCaptureError(_ error: AudioCaptureError, for session: RecordingSession) {
        let missingMicPermission = AVCaptureDevice.authorizationStatus(for: .audio) != .authorized

        let muesliError: MuesliError
        switch error {
        case .noContentToCapture:
            muesliError = .noAudioContent
        case .permissionDenied, .streamStartFailed:
            muesliError = .screenRecordingDenied
        case .microphoneStartFailed:
            muesliError = missingMicPermission ? .microphoneDenied : .captureStartFailed(underlying: error)
        default:
            muesliError = .captureStartFailed(underlying: error)
        }

        // For permission-related errors, try permission recovery flow
        switch error {
        case .permissionDenied, .streamStartFailed:
            let missingTap = !UserDefaults.standard.bool(forKey: "systemAudioPermissionGranted")
            // If both checks say granted (false negative), default to missingTap
            // since system audio tap is what actually failed
            let effectiveMissingTap = missingTap || (!missingTap && !missingMicPermission)
            if let callback = onPermissionRecoveryNeeded {
                logger.warning("Permission error during capture start, triggering recovery: missingTap=\(effectiveMissingTap), missingMic=\(missingMicPermission)")
                callback(effectiveMissingTap, missingMicPermission)
                cleanupFailedSession(session)
                return
            }
        case .microphoneStartFailed:
            if missingMicPermission, let callback = onPermissionRecoveryNeeded {
                logger.warning("Microphone permission error during capture start, triggering recovery")
                callback(false, true)
                cleanupFailedSession(session)
                return
            }
        default:
            break
        }

        // Fallback: show error on session (legacy path)
        session.showError(muesliError)
        cleanupFailedSession(session)
    }
    
    private func handleGenericError(_ error: Error, for session: RecordingSession) {
        let errorMsg = error.localizedDescription

        let muesliError: MuesliError
        if errorMsg.contains("TCC") || errorMsg.contains("declined") || errorMsg.contains("permission") {
            muesliError = .screenRecordingDenied

            // Try permission recovery for TCC/permission errors
            let missingTap = !UserDefaults.standard.bool(forKey: "systemAudioPermissionGranted")
            let missingMic = AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
            let effectiveMissingTap = missingTap || (!missingTap && !missingMic)
            if let callback = onPermissionRecoveryNeeded {
                logger.warning("Generic permission error during capture, triggering recovery: missingTap=\(effectiveMissingTap), missingMic=\(missingMic)")
                callback(effectiveMissingTap, missingMic)
                cleanupFailedSession(session)
                return
            }
        } else {
            muesliError = .captureStartFailed(underlying: error)
        }
        session.showError(muesliError)
        cleanupFailedSession(session)
    }
    
    private func cleanupFailedSession(_ session: RecordingSession) {
        session.isInitializing = false
        session.state = .idle
        activeSession = nil
        resetMuteState()
        // Reset isActivelyRecording so permission re-probing is not permanently suppressed.
        onSessionCompleted?(session, nil)
        
        if fileOutputService.isWriting {
            Task {
                _ = try? await fileOutputService.stopWriting()
            }
        }
    }
    
    /// Stop recording for a session
    func stopRecording(for session: RecordingSession) {
        guard session.id == activeSession?.id else { return }
        
        // Check if title is empty - show prompt sheet
        if session.meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingStopSession = session
            showTitlePromptSheet = true
            return
        }
        
        // Title is set, proceed with stop
        performStopRecording(for: session)
    }
    
    /// Called after title prompt is confirmed
    func confirmStopRecording() {
        guard let session = pendingStopSession else { return }
        pendingStopSession = nil
        performStopRecording(for: session)
    }
    
    /// Discard the current recording without saving
    func discardRecording() {
        guard let session = pendingStopSession ?? activeSession else { return }
        pendingStopSession = nil
        showTitlePromptSheet = false
        
        Task {
            await discardRecordingAsync(for: session)
        }
    }
    
    private func discardRecordingAsync(for session: RecordingSession) async {
        secondPassFinalizationTask?.cancel()
        session.state = .stopping
        session.stopDisplayTimer()
        
        do {
            try await audioCaptureService.stopCapture()
            await transcriptionCoordinator.stopTranscription()
            let directory = try? await fileOutputService.stopWriting()
            
            if let directory = directory {
                try? FileManager.default.removeItem(at: directory)
            }
        } catch {
            // Errors during discard can be ignored
        }
        
        session.state = .idle
        activeSession = nil
        resetMuteState()
        // Reset isActivelyRecording so permission re-probing is not permanently suppressed.
        onSessionCompleted?(session, nil)
    }
    
    private func performStopRecording(for session: RecordingSession) {
        Task {
            await stopRecordingAsync(for: session)
        }
    }
    
    static func automaticFinalizationDecision(
        hasAudioFiles: Bool,
        secondPassEnabled: Bool,
        recordingDuration: TimeInterval,
        minimumDuration: TimeInterval = AudioConfiguration.secondPassMinDurationSeconds
    ) -> AutomaticFinalizationDecision {
        guard hasAudioFiles else {
            return AutomaticFinalizationDecision(shouldLaunchSecondPass: false, skipReason: .noAudioFiles)
        }
        guard secondPassEnabled else {
            return AutomaticFinalizationDecision(shouldLaunchSecondPass: false, skipReason: .preferenceDisabled)
        }
        guard recordingDuration >= minimumDuration else {
            return AutomaticFinalizationDecision(shouldLaunchSecondPass: false, skipReason: .recordingTooShort)
        }
        return AutomaticFinalizationDecision(shouldLaunchSecondPass: true, skipReason: nil)
    }

    private func beginFinalizingLiveState(
        for session: RecordingSession,
        directory overrideDirectory: URL? = nil
    ) -> URL? {
        guard let directory = overrideDirectory ?? session.outputDirectory else { return nil }
        if let existing = transcriptionCoordinator.processingState(for: directory),
           existing.phase == .finalizingLive {
            return directory
        }
        transcriptionCoordinator.beginProcessingState(
            for: directory,
            phase: .finalizingLive,
            startedAt: session.finalizationStartTime ?? Date(),
            cancellable: false
        )
        return directory
    }

    private func stopRecordingAsync(for session: RecordingSession) async {
        session.state = .stopping
        session.stopDisplayTimer()
        session.isFinalizingTranscript = true
        session.finalizationStartTime = Date()
        var finalizingDirectory = beginFinalizingLiveState(for: session)
        let stopStartedAt = Date()
        var stopTiming = StopPhaseTiming()
        
        do {
            let captureStartedAt = Date()
            try await audioCaptureService.stopCapture()
            stopTiming.stopCaptureMs = Int(Date().timeIntervalSince(captureStartedAt) * 1000)

            // Stop file writing and get output directory
            let directory: URL
            do {
                let writingStartedAt = Date()
                directory = try await fileOutputService.stopWriting()
                stopTiming.stopWritingMs = Int(Date().timeIntervalSince(writingStartedAt) * 1000)
            } catch {
                if let finalizingDirectory {
                    transcriptionCoordinator.clearProcessingState(
                        for: finalizingDirectory,
                        phase: .finalizingLive,
                        reason: "stopFailedNoOutputDirectory"
                    )
                }
                session.showError(.outputDirectoryCreationFailed)
                session.state = .completed
                session.isFinalizingTranscript = false
                session.finalizationStartTime = nil
                activeSession = nil
                resetMuteState()
                return
            }
            
            session.outputDirectory = directory
            finalizingDirectory = beginFinalizingLiveState(for: session, directory: directory) ?? finalizingDirectory
            let stopPolicy = stopFinalizationPolicy(for: session, directory: directory)
            let shouldUseBoundedFlush = stopPolicy.decision.shouldLaunchSecondPass &&
                transcriptionCoordinator.transcriptionMode == .live

            let transcriptionStartedAt = Date()
            let flushResult = await transcriptionCoordinator.stopTranscription(
                maxFlushDuration: shouldUseBoundedFlush ? 1.5 : nil,
                allowDeferredFlush: shouldUseBoundedFlush
            )
            stopTiming.stopTranscriptionMs = Int(Date().timeIntervalSince(transcriptionStartedAt) * 1000)
            logger.info(
                "Stop flush result: completedFullFlush=\(flushResult.completedFullFlush), flushDurationMs=\(flushResult.flushDurationMs), remainingSamples=\(flushResult.remainingBufferedSamples), boundedFlush=\(shouldUseBoundedFlush)"
            )
            
            // Handle post-processing transcription if needed
            if transcriptionCoordinator.transcriptionMode == .postProcessing {
                await handlePostProcessingTranscription(for: session, directory: directory)
            }
            
            // Finalize transcript
            session.finalizeTranscript()
            
            // Save transcript blocks to file
            do {
                try fileOutputService.saveTranscriptBlocks(
                    session.transcriptBlocks,
                    title: session.meetingTitle.isEmpty ? "Meeting" : session.meetingTitle,
                    date: session.recordingStartTime ?? Date(),
                    to: directory,
                    filename: nil  // Use default "transcript.md"
                )
            } catch {
                session.showError(.transcriptSaveFailed(underlying: error))
                // Continue - we have audio files even if transcript save failed
            }

            await completeStopFlow(
                for: session,
                directory: directory,
                automaticFinalizationDecision: stopPolicy.decision,
                hasAudioFiles: stopPolicy.hasAudioFiles,
                didStopWithIncompleteBoundedFlush: shouldUseBoundedFlush && !flushResult.completedFullFlush
            )
        } catch {
            if let finalizingDirectory {
                transcriptionCoordinator.clearProcessingState(
                    for: finalizingDirectory,
                    phase: .finalizingLive,
                    reason: "stopFlowFailed"
                )
            }
            session.showError(.transcriptSaveFailed(underlying: error))
        }

        session.isFinalizingTranscript = false
        session.finalizationStartTime = nil
        stopTiming.totalMs = Int(Date().timeIntervalSince(stopStartedAt) * 1000)
        Task {
            await DiagnosticLogger.shared.log(
                .stabilizer,
                "stopTiming: stopCaptureMs=\(stopTiming.stopCaptureMs), stopTranscriptionMs=\(stopTiming.stopTranscriptionMs), stopWritingMs=\(stopTiming.stopWritingMs), totalMs=\(stopTiming.totalMs)"
            )
        }

        activeSession = nil
        resetMuteState()
    }

    private func recordingDuration(for session: RecordingSession) -> TimeInterval {
        session.recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
    }

    private func hasAudioFiles(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("audio.caf").path) ||
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("microphone.caf").path)
    }

    private func stopFinalizationPolicy(
        for session: RecordingSession,
        directory: URL
    ) -> (hasAudioFiles: Bool, decision: AutomaticFinalizationDecision) {
        let hasAudioFiles = hasAudioFiles(in: directory)
        let duration = recordingDuration(for: session)
        let decision = Self.automaticFinalizationDecision(
            hasAudioFiles: hasAudioFiles,
            secondPassEnabled: preferencesManager.isSecondPassASREnabled,
            recordingDuration: duration
        )
        return (hasAudioFiles, decision)
    }

    private func logAutomaticFinalizationSkip(
        reason: AutomaticFinalizationSkipReason,
        recordingDuration: TimeInterval
    ) {
        switch reason {
        case .noAudioFiles:
            logger.info("Skipping automatic finalization: no audio files")
        case .preferenceDisabled:
            logger.info("Skipping automatic finalization: preference disabled")
        case .recordingTooShort:
            logger.info(
                "Skipping automatic finalization: recording too short (\(String(format: "%.1f", recordingDuration))s < \(String(format: "%.1f", AudioConfiguration.secondPassMinDurationSeconds))s)"
            )
        }
    }

    private func runAutomaticFinalizationIfEligible(
        for session: RecordingSession,
        directory: URL,
        decision: AutomaticFinalizationDecision,
        hasAudioFiles: Bool,
        didStopWithIncompleteBoundedFlush: Bool
    ) async -> (hasAudioFiles: Bool, automaticFinalizationLaunched: Bool) {
        var automaticFinalizationLaunched = false
        if decision.shouldLaunchSecondPass {
            session.effectiveLiveModel = transcriptionCoordinator.effectiveLiveModelForSession ?? session.effectiveLiveModel
            transcriptionCoordinator.markSecondPassActive(for: directory)
            launchSecondPassFinalization(
                for: session,
                directory: directory,
                forceRecoveryOnFailure: didStopWithIncompleteBoundedFlush
            )
            automaticFinalizationLaunched = true
            logger.debug("Deferring immediate export until second-pass finalization completes")
        } else if let reason = decision.skipReason {
            let duration = recordingDuration(for: session)
            logAutomaticFinalizationSkip(reason: reason, recordingDuration: duration)
        }

        // When second-pass is running, finalization exports the completed transcript.
        // Skip the immediate export here so stop-flow completion remains responsive.
        if !automaticFinalizationLaunched {
            await exportMeetingIfEnabled(directory: directory)
        }
        return (hasAudioFiles, automaticFinalizationLaunched)
    }

    private func completeStopFlow(
        for session: RecordingSession,
        directory: URL,
        interruptionMessage: String? = nil,
        automaticFinalizationDecision: AutomaticFinalizationDecision,
        hasAudioFiles: Bool,
        didStopWithIncompleteBoundedFlush: Bool
    ) async {
        let finalizationState = await runAutomaticFinalizationIfEligible(
            for: session,
            directory: directory,
            decision: automaticFinalizationDecision,
            hasAudioFiles: hasAudioFiles,
            didStopWithIncompleteBoundedFlush: didStopWithIncompleteBoundedFlush
        )

        session.state = .completed
        // Interruption may end the live capture stream, but history resume affordance
        // is determined from saved audio presence (`MeetingHistoryItem.canResume`).
        session.canResume = true

        if let interruptionMessage {
            session.showErrorMessage(interruptionMessage)
        }

        // Notify completion — refreshes history and selects the new meeting.
        // NOTE: do NOT call onRefreshHistory here; onSessionCompleted already
        // refreshes. A second refresh would replace the MeetingHistoryItem
        // objects, orphaning the selectedMeeting reference.
        onSessionCompleted?(session, directory)

        // Empty-transcript rescue runs AFTER onSessionCompleted so the canonical
        // MeetingHistoryItem exists in meetingHistory.
        // Automatic finalization is the primary path; rescue only runs if it did
        // not launch and the transcript is empty.
        let hasEmptyTranscript = session.transcriptBlocks.isEmpty
        if finalizationState.hasAudioFiles && hasEmptyTranscript && !finalizationState.automaticFinalizationLaunched {
            logger.info("Auto-triggering reprocessing (empty transcript rescue)")
            onAutoReprocessRequested?(directory)
        } else if hasEmptyTranscript && finalizationState.automaticFinalizationLaunched {
            logger.info("Skipping empty-transcript rescue: automatic finalization already launched")
        }

        if !finalizationState.automaticFinalizationLaunched {
            transcriptionCoordinator.clearProcessingState(
                for: directory,
                phase: .finalizingLive,
                reason: "liveFinalizationComplete"
            )
        }
    }
    
    private func launchSecondPassFinalization(
        for session: RecordingSession,
        directory: URL,
        forceRecoveryOnFailure: Bool
    ) {
        let title = session.meetingTitle.isEmpty ? "Meeting" : session.meetingTitle
        let meetingDate = session.recordingStartTime ?? Date()
        let liveModelAtStop = session.effectiveLiveModel
        let transcriptionCoordinator = self.transcriptionCoordinator
        
        do {
            try fileOutputService.saveTranscriptBlocks(
                session.transcriptBlocks,
                title: title,
                date: meetingDate,
                to: directory,
                filename: "transcript.live.md"
            )
        } catch {
            logger.error("Failed to save live snapshot transcript: \(error.localizedDescription)")
        }
        
        secondPassFinalizationTask?.cancel()
        session.isFinalizingTranscript = true
        session.finalizationStartTime = session.finalizationStartTime ?? Date()
        Task {
            await DiagnosticLogger.shared.log(.stabilizer, "secondPass:scheduled dir=\(directory.lastPathComponent)")
        }
        
        secondPassFinalizationTask = Task { [weak self, weak session, transcriptionCoordinator, liveModelAtStop] in
            defer {
                Task { @MainActor in
                    // Fallback clear in case the task exits before runSecondPassASR reaches its internal defer.
                    transcriptionCoordinator.clearSecondPassActive(for: directory)
                    session?.isFinalizingTranscript = false
                    session?.finalizationStartTime = nil
                    self?.onRefreshHistory?()
                }
            }

            guard let self else { return }
            
            do {
                let blocks = try await self.transcriptionCoordinator.runSecondPassASR(
                    in: directory,
                    recordingStartTime: meetingDate,
                    preference: self.preferencesManager.secondPassModelPreference,
                    liveModel: liveModelAtStop
                )
                try Task.checkCancellation()
                let orderingPreview = blocks.prefix(10).map { block in
                    let ts = String(format: "%.2f", block.startTimestamp)
                    let text = String(block.text.prefix(32))
                    return "\(ts)|\(block.speaker.rawValue)|\(text)"
                }
                // #region agent log
                AgentDebugRuntimeLogger.log(
                    runId: "post-fix-order-1",
                    hypothesisId: "O4",
                    location: "RecordingController.swift:launchSecondPassFinalization",
                    message: "Second-pass block ordering preview",
                    data: [
                        "blockCount": blocks.count,
                        "preview": orderingPreview
                    ]
                )
                // #endregion
                
                try self.fileOutputService.saveTranscriptBlocks(
                    blocks,
                    title: title,
                    date: meetingDate,
                    to: directory,
                    filename: "transcript.md"
                )
                
                await MainActor.run {
                    guard let session else { return }
                    session.resetTranscript()
                    for block in blocks {
                        let segment = TranscriptionService.TranscriptSegment(
                            text: block.text,
                            timestamp: block.startTimestamp,
                            speaker: block.speaker == .me ? .me : .them
                        )
                        session.appendTranscriptSegment(segment)
                    }
                    session.finalizeTranscript()
                }
                
                await self.exportMeetingIfEnabled(directory: directory)
                
                await MainActor.run {
                    self.onAutoRefineRequested?(directory)
                }
            } catch is CancellationError {
                self.logger.info("Second-pass finalization cancelled")
                await DiagnosticLogger.shared.log(.stabilizer, "secondPass:cancelled dir=\(directory.lastPathComponent)")
            } catch {
                self.logger.error("Second-pass finalization failed: \(error.localizedDescription)")
                await DiagnosticLogger.shared.log(
                    .stabilizer,
                    "secondPass:failed dir=\(directory.lastPathComponent) error=\(error.localizedDescription)"
                )
                
                // Fallback: if second-pass failed and transcript is empty, or if
                // bounded flush was incomplete, trigger auto-reprocess recovery.
                let transcriptURL = directory.appendingPathComponent("transcript.md")
                let transcriptExists = FileManager.default.fileExists(atPath: transcriptURL.path)
                let transcriptEmpty = transcriptExists && ((try? String(contentsOf: transcriptURL))?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                if forceRecoveryOnFailure || !transcriptExists || transcriptEmpty {
                    await MainActor.run {
                        if forceRecoveryOnFailure {
                            self.logger.info("Second-pass failed after incomplete bounded flush; forcing auto-reprocess recovery")
                        } else {
                            self.logger.info("Second-pass failed with empty transcript; falling back to auto-reprocess")
                        }
                        self.onAutoReprocessRequested?(directory)
                    }
                }
            }
        }
    }
    
    /// Cancel any running second-pass finalization so a manual reprocess can proceed
    /// without ANE resource contention or transcript.md write races.
    func cancelSecondPassIfRunning() {
        guard let task = secondPassFinalizationTask else { return }
        logger.info("Cancelling second-pass: user initiated manual reprocess")
        task.cancel()
        secondPassFinalizationTask = nil
    }
    
    /// Export meeting to exports directory if export is enabled
    private func exportMeetingIfEnabled(directory: URL) async {
        // Check if export is enabled in preferences
        guard preferencesManager.exportEnabled else {
            logger.debug("Export disabled, skipping export")
            return
        }
        
        // Load the meeting from history to get full metadata
        // We need to create a temporary MeetingHistoryItem from the just-saved directory
        guard let meeting = createMeetingHistoryItem(from: directory) else {
            logger.error("Failed to create meeting item for export")
            return
        }
        
        do {
            try await exportService.exportMeeting(meeting)
            
            // Also update the manifest with all meetings
            // Get all meetings from history
            let meetingHistoryService = MeetingHistoryService()
            let allMeetings = meetingHistoryService.discoverMeetings()
            try exportService.generateManifest(for: allMeetings)
            
            logger.info("Successfully exported meeting: \(meeting.title)")
        } catch {
            logger.error("Failed to export meeting: \(error.localizedDescription)")
            // Don't show error to user - export failures are non-critical
        }
    }
    
    /// Create a MeetingHistoryItem from a directory URL (for immediate export after recording)
    private func createMeetingHistoryItem(from directory: URL) -> MeetingHistoryItem? {
        let fileManager = FileManager.default
        let transcriptURL = fileManager.fileExists(atPath: directory.appendingPathComponent("transcript.md").path)
            ? directory.appendingPathComponent("transcript.md")
            : directory.appendingPathComponent("transcript.live.md")
        
        guard fileManager.fileExists(atPath: transcriptURL.path) else {
            return nil
        }
        
        // Parse date from folder name: YYYY-MM-DD_HH-MM_[UUID]
        let folderName = directory.lastPathComponent
        let components = folderName.components(separatedBy: "_")
        var date = Date()
        
        if components.count >= 2 {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm"
            if let parsed = dateFormatter.date(from: "\(components[0])_\(components[1])") {
                date = parsed
            }
        }
        
        // Read transcript to get title
        var title = "Meeting"
        if let content = try? String(contentsOf: transcriptURL, encoding: .utf8) {
            let lines = content.components(separatedBy: .newlines)
            if let firstLine = lines.first, firstLine.hasPrefix("# ") {
                title = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if title.isEmpty {
                    title = "Meeting"
                }
            }
        }
        
        // Check for audio files
        let audioURL = directory.appendingPathComponent("audio.caf")
        let micURL = directory.appendingPathComponent("microphone.caf")
        let hasAudio = fileManager.fileExists(atPath: audioURL.path)
        let hasMicrophone = fileManager.fileExists(atPath: micURL.path)
        
        // Extract UUID from folder name
        let id = components.count >= 3 ? UUID(uuidString: components[2]) ?? UUID() : UUID()
        
        return MeetingHistoryItem(
            id: id,
            title: title,
            date: date,
            directory: directory,
            hasAudio: hasAudio,
            hasMicrophone: hasMicrophone
        )
    }
    
    private func handlePostProcessingTranscription(for session: RecordingSession, directory: URL) async {
        session.transcriptText = "Processing transcript..."
        
        let systemAudioURL = directory.appendingPathComponent("audio.caf")
        let micAudioURL = directory.appendingPathComponent("microphone.caf")
        
        do {
            session.transcriptText = ""
            try await transcriptionService.transcribePostProcessing(
                systemAudioURL: FileManager.default.fileExists(atPath: systemAudioURL.path) ? systemAudioURL : nil,
                micAudioURL: FileManager.default.fileExists(atPath: micAudioURL.path) ? micAudioURL : nil,
                startTime: session.recordingStartTime ?? Date()
            )
        } catch {
            session.showError(.postProcessingFailed(underlying: error))
        }
    }
    
    // MARK: - Model Error Handling
    
    func startRecordingWithoutTranscription() {
        guard let session = sessionPendingModelDecision else { return }
        sessionPendingModelDecision = nil
        showModelErrorAlert = false
        
        // Recording is already in progress (audio capture started), just dismiss the alert
        // The session will continue recording without transcription
        // Mark session as recording-only mode
        session.isRecordingOnly = true
    }
    
    func cancelRecordingDueToModelError() {
        sessionPendingModelDecision = nil
        showModelErrorAlert = false
    }
    
    // MARK: - Capture Interruption
    
    private func handleCaptureInterrupted(error: Error?) {
        guard let session = activeSession else { return }

        guard session.state == .recording else {
            logger.info("Ignoring duplicate capture interruption while session is not actively recording")
            return
        }

        // Move to stopping immediately so repeated interruption callbacks become no-ops.
        session.state = .stopping
        session.stopDisplayTimer()
        session.wasInterrupted = true
        if session.interruptionReason == nil {
            session.interruptionReason = "The captured app was closed"
        }

        let reason = session.interruptionReason ?? "The captured stream was interrupted"
        let errorDescription = error?.localizedDescription ?? "none"
        logger.warning("RECORDING_INTERRUPTED: reason=\(reason), error=\(errorDescription)")
        Task {
            await DiagnosticLogger.shared.log(
                .app,
                "RECORDING_INTERRUPTED: reason=\(reason), error=\(errorDescription)"
            )
        }

        Task {
            await stopRecordingAfterInterruption(for: session)
        }
    }
    
    private func stopRecordingAfterInterruption(for session: RecordingSession) async {
        if session.state != .stopping {
            session.state = .stopping
            session.stopDisplayTimer()
        }
        session.isFinalizingTranscript = true
        session.finalizationStartTime = Date()
        var finalizingDirectory = beginFinalizingLiveState(for: session)
        let stopStartedAt = Date()
        var stopTiming = StopPhaseTiming()
        
        do {
            // Interruption has already terminated the source stream, so this path
            // intentionally does NOT call audioCaptureService.stopCapture().
            // Stop file writing and get output directory
            let directory: URL
            do {
                let writingStartedAt = Date()
                directory = try await fileOutputService.stopWriting()
                stopTiming.stopWritingMs = Int(Date().timeIntervalSince(writingStartedAt) * 1000)
            } catch {
                if let finalizingDirectory {
                    transcriptionCoordinator.clearProcessingState(
                        for: finalizingDirectory,
                        phase: .finalizingLive,
                        reason: "interruptedStopFailedNoOutputDirectory"
                    )
                }
                session.state = .completed
                session.showError(.outputDirectoryCreationFailed)
                session.isFinalizingTranscript = false
                session.finalizationStartTime = nil
                activeSession = nil
                resetMuteState()
                // Reset isActivelyRecording so permission re-probing is not permanently suppressed.
                onSessionCompleted?(session, nil)
                return
            }
            
            session.outputDirectory = directory
            finalizingDirectory = beginFinalizingLiveState(for: session, directory: directory) ?? finalizingDirectory
            let stopPolicy = stopFinalizationPolicy(for: session, directory: directory)
            let shouldUseBoundedFlush = stopPolicy.decision.shouldLaunchSecondPass &&
                transcriptionCoordinator.transcriptionMode == .live

            let transcriptionStartedAt = Date()
            let flushResult = await transcriptionCoordinator.stopTranscription(
                maxFlushDuration: shouldUseBoundedFlush ? 1.5 : nil,
                allowDeferredFlush: shouldUseBoundedFlush
            )
            stopTiming.stopTranscriptionMs = Int(Date().timeIntervalSince(transcriptionStartedAt) * 1000)
            logger.info(
                "Interrupted stop flush result: completedFullFlush=\(flushResult.completedFullFlush), flushDurationMs=\(flushResult.flushDurationMs), remainingSamples=\(flushResult.remainingBufferedSamples), boundedFlush=\(shouldUseBoundedFlush)"
            )
            
            if transcriptionCoordinator.transcriptionMode == .postProcessing {
                await handlePostProcessingTranscription(for: session, directory: directory)
            }
            
            session.finalizeTranscript()
            
            // Save transcript blocks
            do {
                try fileOutputService.saveTranscriptBlocks(
                    session.transcriptBlocks,
                    title: session.meetingTitle.isEmpty ? "Meeting" : session.meetingTitle,
                    date: session.recordingStartTime ?? Date(),
                    to: directory,
                    filename: nil
                )
            } catch {
                session.showError(.transcriptSaveFailed(underlying: error))
                // Continue - we have audio files even if transcript save failed
            }

            let interruptionMessage = "Recording saved. \(session.interruptionReason ?? "The stream was interrupted.")"
            await completeStopFlow(
                for: session,
                directory: directory,
                interruptionMessage: interruptionMessage,
                automaticFinalizationDecision: stopPolicy.decision,
                hasAudioFiles: stopPolicy.hasAudioFiles,
                didStopWithIncompleteBoundedFlush: shouldUseBoundedFlush && !flushResult.completedFullFlush
            )
        } catch {
            if let finalizingDirectory {
                transcriptionCoordinator.clearProcessingState(
                    for: finalizingDirectory,
                    phase: .finalizingLive,
                    reason: "interruptedStopFlowFailed"
                )
            }
            session.showError(.transcriptSaveFailed(underlying: error))
        }

        session.isFinalizingTranscript = false
        session.finalizationStartTime = nil
        stopTiming.totalMs = Int(Date().timeIntervalSince(stopStartedAt) * 1000)
        Task {
            await DiagnosticLogger.shared.log(
                .stabilizer,
                "interruptedStopTiming: stopTranscriptionMs=\(stopTiming.stopTranscriptionMs), stopWritingMs=\(stopTiming.stopWritingMs), totalMs=\(stopTiming.totalMs)"
            )
        }

        activeSession = nil
        resetMuteState()
    }
    
    // MARK: - Resume Recording
    
    func resumeRecording(for meeting: MeetingHistoryItem) {
        guard meeting.canResume else { return }
        guard activeSession == nil else { return }
        
        Task {
            await resumeRecordingAsync(for: meeting)
        }
    }
    
    private func resumeRecordingAsync(for meeting: MeetingHistoryItem) async {
        do {
            // Reset retry budget for a fresh recording session
            transcriptionCoordinator.resetForNewRecording()
            
            let modelState = await transcriptionCoordinator.prepareModel()
            
            switch modelState {
            case .notAvailable:
                logger.error("Cannot resume: No transcription model available")
                warningManager.addWarning(
                    .modelLoading,
                    message: "No transcription model available",
                    details: "Please download a transcription model from Preferences before resuming recording.",
                    canRetry: false
                )
                return
            case .failed(let error):
                logger.error("Cannot resume: Model failed to load: \(error)")
                warningManager.addWarning(
                    .modelLoading,
                    message: "Model failed to load",
                    details: "Error: \(error.localizedDescription)\n\nPlease try restarting the app or re-downloading the model from Preferences.",
                    canRetry: false
                )
                return
            case .loading, .ready:
                break
            }
            
            let session = createSession()
            session.parentMeeting = meeting
            session.resumeCount = meeting.segmentCount
            session.segmentNumber = meeting.segmentCount + 1
            session.meetingTitle = meeting.title
            
            activeSession = session
            let mutedState = session.isMicrophoneMuted
            isMicrophoneMutedLock.withLock { $0 = mutedState }
            
            // Notify ViewModel that session started
            onSessionStarted?(session)
            
            transcriptionCoordinator.setTranscriptHandler { [weak session] (segment: TranscriptionService.TranscriptSegment) in
                Task { @MainActor in
                    guard let session = session else { return }
                    session.appendTranscriptSegment(segment)
                }
            }
            transcriptionCoordinator.setDraftHandler { [weak session] draftText, speaker in
                Task { @MainActor in
                    guard let session = session else { return }
                    session.updateLiveDraft(
                        draftText,
                        speaker: speaker == .me ? .me : .them
                    )
                }
            }
            
            let saveRaw = preferencesManager.saveRawMicrophoneAudio
            session.outputDirectory = try fileOutputService.resumeWriting(
                to: meeting.directory,
                segmentNumber: session.segmentNumber,
                saveRawMicrophone: saveRaw
            )
            
            let aecOn = preferencesManager.echoCancellationEnabledForAudioCallback
            logger.info("MIC_FILE_OUTPUT (resume): aecEnabled=\(aecOn), saveRaw=\(saveRaw), routing=.microphone from processed path")
            Task {
                await DiagnosticLogger.shared.log(.app,
                    "MIC_FILE_OUTPUT (resume): aecEnabled=\(aecOn), saveRaw=\(saveRaw), routing=.microphone from processed path")
            }
            
            // Pass selected mic device to audio capture service for AVAudioEngine capture
            let selectedMicID = microphoneManager.selectedDeviceID
            await audioCaptureService.setMicrophoneDevice(selectedMicID)
            
            // CRITICAL: Ensure audio handlers are configured BEFORE starting capture
            await ensureAudioHandlersConfigured()
            
            try await audioCaptureService.startCapture()
            
            session.isInitializing = false
            session.state = .recording
            session.recordingStartTime = Date()
            session.transcriptText = ""
            session.transcriptBlocks = []
            session.resetTranscript()
            session.startDisplayTimer()
            
            transcriptionCoordinator.startTranscription(recordingStartTime: session.recordingStartTime ?? Date())
        } catch let error as AudioCaptureError {
            if let session = activeSession {
                handleCaptureError(error, for: session)
            }
        } catch {
            if let session = activeSession {
                handleGenericError(error, for: session)
            }
        }
    }
    
    // MARK: - Re-transcription
    
    func retranscribeWithPostProcessing(for session: RecordingSession) {
        guard session.canRetranscribe, !session.isRetranscribing else { return }
        
        Task {
            await retranscribeWithPostProcessingAsync(for: session)
        }
    }
    
    private func retranscribeWithPostProcessingAsync(for session: RecordingSession) async {
        guard let directory = session.outputDirectory else {
            session.showError(.meetingDirectoryNotFound)
            return
        }
        
        session.isRetranscribing = true
        
        // Reset retry budget for a fresh model load attempt
        transcriptionCoordinator.resetForNewRecording()
        
        let modelState = await transcriptionCoordinator.prepareModel()
        
        switch modelState {
        case .notAvailable:
            session.isRetranscribing = false
            session.showError(.modelNotFound)
            return
        case .failed(let error):
            session.isRetranscribing = false
            session.showError(.modelLoadFailed(underlying: error))
            return
        case .loading, .ready:
            break
        }
        
        let previousMode = transcriptionCoordinator.transcriptionMode
        transcriptionCoordinator.setTranscriptionMode(.postProcessing)
        
        transcriptionCoordinator.setTranscriptHandler { [weak session] (segment: TranscriptionService.TranscriptSegment) in
            Task { @MainActor in
                guard let session = session else { return }
                session.appendTranscriptSegment(segment)
            }
        }
        transcriptionCoordinator.setDraftHandler { _, _ in }
        
        let systemAudioURL = directory.appendingPathComponent("audio.caf")
        let micAudioURL = directory.appendingPathComponent("microphone.caf")
        
        do {
            session.resetTranscript()
            
            try await transcriptionService.transcribePostProcessing(
                systemAudioURL: FileManager.default.fileExists(atPath: systemAudioURL.path) ? systemAudioURL : nil,
                micAudioURL: FileManager.default.fileExists(atPath: micAudioURL.path) ? micAudioURL : nil,
                startTime: session.recordingStartTime ?? Date()
            )
            
            session.finalizeTranscript()
            
            let title = session.meetingTitle.isEmpty ? "Meeting" : session.meetingTitle
            do {
                try fileOutputService.saveTranscriptBlocks(
                    session.transcriptBlocks,
                    title: title,
                    date: session.recordingStartTime ?? Date(),
                    to: directory,
                    filename: nil  // Use default "transcript.md"
                )
            } catch {
                session.showError(.transcriptSaveFailed(underlying: error))
                // Continue - retranscription succeeded even if save failed
            }
        } catch {
            session.showError(.postProcessingFailed(underlying: error))
        }
        
        transcriptionCoordinator.setTranscriptionMode(previousMode)
        session.isRetranscribing = false
    }
    
    // MARK: - Microphone Mute
    
    func toggleMicrophoneMute() {
        guard let session = activeSession else { return }
        session.isMicrophoneMuted.toggle()
        let mutedState = session.isMicrophoneMuted
        isMicrophoneMutedLock.withLock { $0 = mutedState }
    }
    
    private func resetMuteState() {
        isMicrophoneMutedLock.withLock { $0 = false }
    }

    // MARK: - Microphone Device Selection
    
    func handleMicrophoneDeviceChange(_ deviceID: String?) {
        guard let session = activeSession, session.isRecording else { return }
        
        Task {
            await audioCaptureService.setMicrophoneDevice(deviceID)
        }
    }
}
