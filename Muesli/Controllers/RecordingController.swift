import Foundation
import SwiftUI
import ScreenCaptureKit
import CoreMedia
import os.lock

/// Controller responsible for recording lifecycle management
/// Extracted from MuesliViewModel to improve separation of concerns
@Observable
@MainActor
final class RecordingController {
    
    // MARK: - Dependencies
    
    private let audioCaptureService: AudioCaptureService
    private let fileOutputService: FileOutputService
    private let transcriptionService: TranscriptionService
    private let transcriptionCoordinator: TranscriptionCoordinator
    private let echoCancellationService: EchoCancellationService
    private let preferencesManager: PreferencesManager
    private let microphoneManager: MicrophoneManager
    
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
    
    // MARK: - Audio Level Throttling
    
    /// Last time microphone level was updated (for throttling UI updates)
    private var lastMicLevelUpdate = Date.distantPast
    
    /// Last time system audio level was updated (for throttling UI updates)
    private var lastSystemLevelUpdate = Date.distantPast
    
    /// Minimum interval between audio level UI updates (~30fps)
    private let levelUpdateInterval: TimeInterval = 0.033
    
    // MARK: - Thread-safe Mute State
    
    /// Microphone mute state (for synchronous access from audio callback)
    /// Uses OSAllocatedUnfairLock for proper thread-safe access
    private let isMicrophoneMutedLock = OSAllocatedUnfairLock(initialState: false)
    
    /// Thread-safe getter for audio callbacks (nonisolated)
    nonisolated var isMicrophoneMutedSafe: Bool {
        isMicrophoneMutedLock.withLock { $0 }
    }
    
    // MARK: - Callbacks
    
    /// Called when active session changes (for history manager updates)
    var onSessionCompleted: ((RecordingSession, URL?) -> Void)?
    
    /// Called when meeting history should be refreshed
    var onRefreshHistory: (() -> Void)?
    
    // MARK: - Initialization
    
    init(
        audioCaptureService: AudioCaptureService,
        fileOutputService: FileOutputService,
        transcriptionService: TranscriptionService,
        transcriptionCoordinator: TranscriptionCoordinator,
        echoCancellationService: EchoCancellationService,
        preferencesManager: PreferencesManager,
        microphoneManager: MicrophoneManager
    ) {
        self.audioCaptureService = audioCaptureService
        self.fileOutputService = fileOutputService
        self.transcriptionService = transcriptionService
        self.transcriptionCoordinator = transcriptionCoordinator
        self.echoCancellationService = echoCancellationService
        self.preferencesManager = preferencesManager
        self.microphoneManager = microphoneManager
        
        // Set up audio buffer handler
        setupAudioBufferHandler()
    }
    
    // MARK: - Audio Buffer Handler Setup
    
    private func setupAudioBufferHandler() {
        let fileService = self.fileOutputService
        let transcriptService = self.transcriptionService
        let aecService = self.echoCancellationService
        let prefs = self.preferencesManager
        let audioCaptureServiceRef = self.audioCaptureService
        
        Task {
            await audioCaptureServiceRef.setBufferHandler { [weak self] buffer, type in
                guard let self = self else { return }
                
                // Check if microphone is muted (thread-safe synchronous check)
                let isMicMuted = self.isMicrophoneMutedSafe
                // Read AEC state from PreferencesManager's nonisolated accessor
                let isAECEnabled = prefs.echoCancellationEnabledForAudioCallback
                
                let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer)
                
                switch type {
                case .system:
                    // Store system audio for AEC reference (if AEC enabled)
                    if isAECEnabled {
                        if let systemSamples = EchoCancellationService.extractSamples(from: buffer) {
                            aecService.storeSystemAudio(samples: systemSamples, timestamp: timestamp)
                        }
                    }
                    
                    // Save to file (always)
                    fileService.appendAudioBuffer(buffer, type: type)
                    
                    // Feed to transcription in live mode
                    if transcriptService.transcriptionMode == .live {
                        if let samples = TranscriptionService.resampleToWhisperFormat(
                            buffer,
                            sourceSampleRate: 48000,
                            sourceChannels: 2
                        ) {
                            transcriptService.appendSystemAudio(samples)
                        }
                    }
                    
                case .microphone:
                    // Extract microphone samples at 48kHz
                    guard let micSamples48kHz = EchoCancellationService.extractSamples(from: buffer) else {
                        // Fallback: save original buffer
                        fileService.appendAudioBuffer(buffer, type: type)
                        return
                    }
                    
                    // Apply AEC if enabled
                    let processedSamples48kHz: [Float]
                    if isAECEnabled {
                        processedSamples48kHz = aecService.processMicrophoneAudio(
                            microphoneSamples: micSamples48kHz,
                            micTimestamp: timestamp
                        )
                        
                        // Create CMSampleBuffer from processed samples for file output
                        if let processedBuffer = EchoCancellationService.createSampleBuffer(
                            from: processedSamples48kHz,
                            timestamp: timestamp
                        ) {
                            fileService.appendAudioBuffer(processedBuffer, type: type)
                        } else {
                            // Fallback: save original if conversion fails
                            fileService.appendAudioBuffer(buffer, type: type)
                        }
                    } else {
                        processedSamples48kHz = micSamples48kHz
                        // Save original buffer when AEC disabled
                        fileService.appendAudioBuffer(buffer, type: type)
                    }
                    
                    // Skip microphone audio for transcription if muted
                    if isMicMuted {
                        return
                    }
                    
                    // Feed to transcription in live mode
                    if transcriptService.transcriptionMode == .live {
                        // Resample processed samples to 16kHz for transcription
                        let resampled = EchoCancellationService.resampleFloat32Public(
                            samples: processedSamples48kHz,
                            sourceSampleRate: 48000,
                            targetSampleRate: 16000
                        )
                        transcriptService.appendMicrophoneAudio(resampled)
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
        }
    }
    
    // MARK: - Session Management
    
    /// Create a new recording session
    func createSession() -> RecordingSession {
        return RecordingSession()
    }
    
    /// Update audio level for the active session (throttled to ~30fps)
    private func updateAudioLevel(_ level: Float, type: AudioCaptureService.AudioType) {
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
        }
    }
    
    // MARK: - Recording Actions
    
    /// Quick start recording with all system audio (no app selection needed)
    func quickStartRecording() {
        guard activeSession == nil else {
            return  // Already recording
        }
        
        // Create a new session with no app filter (captures all system audio)
        let session = createSession()
        session.selectedApp = nil  // All system audio
        
        // Use default microphone
        if let defaultMic = microphoneManager.currentDefaultDevice {
            microphoneManager.setSelectedDeviceID(defaultMic.id)
        }
        
        // Ensure live transcription mode
        transcriptionCoordinator.setTranscriptionMode(.live)
        
        // Start recording
        startRecording(for: session)
    }
    
    /// Start recording for a session
    func startRecording(for session: RecordingSession) {
        // Only one session can record at a time
        guard activeSession == nil else {
            session.showErrorMessage("Another recording is already in progress.")
            return
        }
        
        // Set activeSession immediately so UI shows recording view right away
        activeSession = session
        let mutedState = session.isMicrophoneMuted
        isMicrophoneMutedLock.withLock { $0 = mutedState }
        
        // Mark as initializing (loading model)
        session.isInitializing = true
        
        Task {
            await startRecordingAsync(for: session)
        }
    }
    
    private func startRecordingAsync(for session: RecordingSession) async {
        do {
            // Prepare transcription model using coordinator
            let modelState = await transcriptionCoordinator.prepareModel()
            
            switch modelState {
            case .notAvailable:
                session.isInitializing = false
                session.state = .idle
                activeSession = nil
                resetMuteState()
                sessionPendingModelDecision = session
                showModelErrorAlert = true
                return
                
            case .loading, .ready:
                // Continue with recording setup
                break
                
            case .failed(let error):
                session.isInitializing = false
                session.state = .idle
                activeSession = nil
                resetMuteState()
                session.showErrorMessage("Model failed to load: \(error.localizedDescription)")
                sessionPendingModelDecision = session
                showModelErrorAlert = true
                return
            }
            
            // Set up transcript handler through coordinator
            transcriptionCoordinator.setTranscriptHandler { [weak session] (segment: TranscriptionService.TranscriptSegment) in
                Task { @MainActor in
                    guard let session = session else { return }
                    session.appendTranscriptSegment(segment)
                }
            }
            
            // Start file output first
            session.outputDirectory = try fileOutputService.startWriting()
            
            // Configure microphone preference before starting capture
            if let selectedMicID = microphoneManager.selectedDeviceID {
                microphoneManager.setSelectedDeviceID(selectedMicID)
            }
            
            // Start audio capture
            if let app = session.selectedApp {
                try await audioCaptureService.startCapture(forBundleIdentifier: app.bundleIdentifier)
            } else {
                try await audioCaptureService.startCapture()
            }
            
            // Update session state on success
            session.isInitializing = false
            session.state = .recording
            session.recordingStartTime = Date()
            session.transcriptText = ""
            session.startDisplayTimer()
            
            // Reset echo cancellation filter for new recording
            echoCancellationService.reset()
            
            // Start transcription through coordinator
            transcriptionCoordinator.startTranscription(recordingStartTime: session.recordingStartTime ?? Date())
            
        } catch let error as AudioCaptureService.CaptureError {
            handleCaptureError(error, for: session)
        } catch {
            handleGenericError(error, for: session)
        }
    }
    
    private func handleCaptureError(_ error: AudioCaptureService.CaptureError, for session: RecordingSession) {
        switch error {
        case .noContentToCapture:
            if let app = session.selectedApp {
                session.showErrorMessage("Could not find \(app.name). Make sure it's running and has a window open.")
            } else {
                session.showErrorMessage("No audio content available to capture.")
            }
        case .permissionDenied, .streamStartFailed:
            session.showErrorMessage("Please grant Screen Recording permission and try again.")
        default:
            session.showErrorMessage("Failed to start recording: \(error.localizedDescription)")
        }
        cleanupFailedSession(session)
    }
    
    private func handleGenericError(_ error: Error, for session: RecordingSession) {
        let errorMsg = error.localizedDescription
        
        if errorMsg.contains("TCC") || errorMsg.contains("declined") || errorMsg.contains("permission") {
            session.showErrorMessage("Please grant Screen Recording permission and try again.")
        } else {
            session.showErrorMessage("Failed to start recording: \(errorMsg)")
        }
        cleanupFailedSession(session)
    }
    
    private func cleanupFailedSession(_ session: RecordingSession) {
        session.isInitializing = false
        session.state = .idle
        activeSession = nil
        resetMuteState()
        
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
        session.state = .stopping
        session.stopDisplayTimer()
        
        do {
            try await audioCaptureService.stopCapture()
            echoCancellationService.reset()
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
    }
    
    private func performStopRecording(for session: RecordingSession) {
        Task {
            await stopRecordingAsync(for: session)
        }
    }
    
    private func stopRecordingAsync(for session: RecordingSession) async {
        session.state = .stopping
        session.stopDisplayTimer()
        
        do {
            try await audioCaptureService.stopCapture()
            echoCancellationService.reset()
            await transcriptionCoordinator.stopTranscription()
            
            guard let directory = try? await fileOutputService.stopWriting() else {
                session.state = .completed
                activeSession = nil
                resetMuteState()
                return
            }
            
            session.outputDirectory = directory
            
            // Handle post-processing transcription if needed
            if transcriptionCoordinator.transcriptionMode == .postProcessing {
                await handlePostProcessingTranscription(for: session, directory: directory)
            }
            
            // Finalize transcript
            session.finalizeTranscript()
            
            // Save transcript blocks to file
            try? fileOutputService.saveTranscriptBlocks(
                session.transcriptBlocks,
                title: session.meetingTitle.isEmpty ? "Meeting" : session.meetingTitle,
                date: session.recordingStartTime ?? Date(),
                to: directory
            )
            
        } catch {
            session.showErrorMessage("Error stopping recording: \(error.localizedDescription)")
        }
        
        // Mark session as completed
        session.state = .completed
        session.canResume = true
        
        // Notify completion
        onSessionCompleted?(session, session.outputDirectory)
        onRefreshHistory?()
        
        activeSession = nil
        resetMuteState()
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
            session.showErrorMessage("Post-processing transcription failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Model Error Handling
    
    func startRecordingWithoutTranscription() {
        guard let session = sessionPendingModelDecision else { return }
        sessionPendingModelDecision = nil
        showModelErrorAlert = false
        session.showErrorMessage("Recording without transcription is not yet supported. Please download a working model in Preferences.")
    }
    
    func cancelRecordingDueToModelError() {
        sessionPendingModelDecision = nil
        showModelErrorAlert = false
    }
    
    // MARK: - Capture Interruption
    
    private func handleCaptureInterrupted(error: Error?) {
        guard let session = activeSession else { return }
        
        session.wasInterrupted = true
        session.interruptionReason = "The captured app was closed"
        
        Task {
            await stopRecordingAfterInterruption(for: session)
        }
    }
    
    private func stopRecordingAfterInterruption(for session: RecordingSession) async {
        session.state = .stopping
        session.stopDisplayTimer()
        
        do {
            echoCancellationService.reset()
            await transcriptionCoordinator.stopTranscription()
            
            guard let directory = try? await fileOutputService.stopWriting() else {
                session.state = .completed
                session.showErrorMessage("Recording was interrupted: \(session.interruptionReason ?? "Unknown reason")")
                activeSession = nil
                resetMuteState()
                return
            }
            
            session.outputDirectory = directory
            
            if transcriptionCoordinator.transcriptionMode == .postProcessing {
                await handlePostProcessingTranscription(for: session, directory: directory)
            }
            
            session.finalizeTranscript()
            try? fileOutputService.saveTranscriptBlocks(
                session.transcriptBlocks,
                title: session.meetingTitle.isEmpty ? "Meeting" : session.meetingTitle,
                date: session.recordingStartTime ?? Date(),
                to: directory
            )
            
        } catch {
            session.showErrorMessage("Error saving interrupted recording: \(error.localizedDescription)")
        }
        
        session.state = .completed
        session.showErrorMessage("Recording saved. \(session.interruptionReason ?? "The stream was interrupted.")")
        
        onRefreshHistory?()
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
            let modelState = await transcriptionCoordinator.prepareModel()
            
            switch modelState {
            case .notAvailable, .failed:
                return
            case .loading, .ready:
                break
            }
            
            let session = createSession()
            session.parentMeeting = meeting
            session.resumeCount = meeting.segmentCount
            session.segmentNumber = meeting.segmentCount + 1
            session.meetingTitle = meeting.title
            session.selectedApp = nil
            
            activeSession = session
            let mutedState = session.isMicrophoneMuted
            isMicrophoneMutedLock.withLock { $0 = mutedState }
            
            transcriptionCoordinator.setTranscriptHandler { [weak session] (segment: TranscriptionService.TranscriptSegment) in
                Task { @MainActor in
                    guard let session = session else { return }
                    session.appendTranscriptSegment(segment)
                }
            }
            
            session.outputDirectory = try fileOutputService.resumeWriting(
                to: meeting.directory,
                segmentNumber: session.segmentNumber
            )
            
            if let selectedMicID = microphoneManager.selectedDeviceID {
                microphoneManager.setSelectedDeviceID(selectedMicID)
            }
            
            try await audioCaptureService.startCapture()
            
            session.isInitializing = false
            session.state = .recording
            session.recordingStartTime = Date()
            session.transcriptText = ""
            session.transcriptBlocks = []
            session.resetTranscript()
            session.startDisplayTimer()
            
            transcriptionCoordinator.startTranscription(recordingStartTime: session.recordingStartTime ?? Date())
            
        } catch let error as AudioCaptureService.CaptureError {
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
            session.showErrorMessage("No recording directory found.")
            return
        }
        
        session.isRetranscribing = true
        
        let modelState = await transcriptionCoordinator.prepareModel()
        
        switch modelState {
        case .notAvailable:
            session.isRetranscribing = false
            session.showErrorMessage("No transcription model configured.")
            return
        case .failed(let error):
            session.isRetranscribing = false
            session.showErrorMessage("Failed to initialize transcription: \(error.localizedDescription)")
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
            try? fileOutputService.saveTranscriptBlocks(
                session.transcriptBlocks,
                title: title,
                date: session.recordingStartTime ?? Date(),
                to: directory
            )
            
        } catch {
            session.showErrorMessage("Re-transcription failed: \(error.localizedDescription)")
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
}
