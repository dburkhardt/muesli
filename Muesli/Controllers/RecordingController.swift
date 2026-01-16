import Foundation
import SwiftUI
import ScreenCaptureKit
import CoreMedia
import os.lock

// #region agent log
fileprivate extension String {
    func appendToDebugLog(atPath path: String) {
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
    
    /// Called when split view visibility should change
    var onSplitViewVisibilityChanged: ((Bool) -> Void)?
    
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
        
        // Note: Audio buffer handler is set up in ensureAudioHandlersConfigured() before each recording
    }
    
    deinit {
        print("[RecordingController] Deallocating")
    }
    
    // MARK: - Audio Buffer Handler Setup
    
    /// Ensures audio handlers are configured before starting capture
    /// Must be called (and awaited) before audioCaptureService.startCapture()
    private func ensureAudioHandlersConfigured() async {
        // #region agent log
        let logPath = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
        let logEntry0 = try? JSONSerialization.data(withJSONObject: ["sessionId":"debug-session","runId":"post-fix","hypothesisId":"K","location":"RecordingController.swift:ensureAudioHandlersConfigured","message":"ensureAudioHandlersConfigured ENTRY","data":[String:String](),"timestamp":Date().timeIntervalSince1970*1000])
        if let data = logEntry0, let json = String(data: data, encoding: .utf8) { (json + "\n").appendToDebugLog(atPath: logPath) }
        // #endregion
        
        let fileService = self.fileOutputService
        let transcriptService = self.transcriptionService
        let transcriptionCoordinator = self.transcriptionCoordinator
        let aecService = self.echoCancellationService
        let prefs = self.preferencesManager
        let audioCaptureServiceRef = self.audioCaptureService
        
        // Capture locks directly to avoid @MainActor isolation in callback
        let muteLock = self.isMicrophoneMutedLock
        let aecLock = prefs.echoCancellationLock
        
        // #region agent log
        let logEntry1 = try? JSONSerialization.data(withJSONObject: ["sessionId":"debug-session","runId":"post-fix","hypothesisId":"K","location":"RecordingController.swift:ensureAudioHandlersConfigured","message":"About to call setBufferHandler","data":[String:String](),"timestamp":Date().timeIntervalSince1970*1000])
        if let data = logEntry1, let json = String(data: data, encoding: .utf8) { (json + "\n").appendToDebugLog(atPath: logPath) }
        // #endregion
        
        await audioCaptureServiceRef.setBufferHandler { [weak self] buffer, type in
                // #region agent log
                let logPath = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
                let typeStr = type == .system ? "system" : "microphone"
                let logData = try? JSONSerialization.data(withJSONObject: ["sessionId":"debug-session","runId":"initial","hypothesisId":"F","location":"RecordingController.swift:bufferHandler","message":"Buffer handler callback invoked","data":["type":typeStr],"timestamp":Date().timeIntervalSince1970*1000])
                if let data = logData, let json = String(data: data, encoding: .utf8) { (json + "\n").appendToDebugLog(atPath: logPath) }
                // #endregion
                
                // Wrap entire handler in error handling for graceful degradation
                do {
                    // NO direct self capture in processing - only use captured locks and services (thread-safe)
                    let isMicMuted = muteLock.withLock { $0 }
                    let isAECEnabled = aecLock.withLock { $0 }
                    
                    let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer)
                    
                    switch type {
                    case .system:
                        try RecordingController.handleSystemAudioBuffer(
                            buffer,
                            timestamp: timestamp,
                            isAECEnabled: isAECEnabled,
                            fileService: fileService,
                            transcriptionCoordinator: transcriptionCoordinator,
                            aecService: aecService
                        )
                        
                    case .microphone:
                        try RecordingController.handleMicrophoneAudioBuffer(
                            buffer,
                            timestamp: timestamp,
                            isMicMuted: isMicMuted,
                            isAECEnabled: isAECEnabled,
                            fileService: fileService,
                            transcriptionCoordinator: transcriptionCoordinator,
                            aecService: aecService
                        )
                    }
                    
                    // Reset error counter on success
                    Task { @MainActor in
                        self?.audioErrorCounter = 0
                    }
                    
                } catch {
                    // Log error but continue processing
                    print("[RecordingController] Audio buffer processing error: \(error)")
                    
                    Task { @MainActor in
                        guard let self = self else { return }
                        self.audioErrorCounter += 1
                        
                        // If too many consecutive errors, stop recording gracefully
                        if self.audioErrorCounter > self.maxConsecutiveAudioErrors {
                            print("[RecordingController] Too many consecutive audio errors (\(self.audioErrorCounter)), stopping recording")
                            
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
        
        // #region agent log
        let logPath2 = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
        let logEntry2 = try? JSONSerialization.data(withJSONObject: ["sessionId":"debug-session","runId":"post-fix","hypothesisId":"K","location":"RecordingController.swift:ensureAudioHandlersConfigured","message":"ensureAudioHandlersConfigured COMPLETE - all handlers set","data":[String:String](),"timestamp":Date().timeIntervalSince1970*1000])
        if let data = logEntry2, let json = String(data: data, encoding: .utf8) { (json + "\n").appendToDebugLog(atPath: logPath2) }
        // #endregion
    }
    
    // MARK: - Audio Buffer Processing Helpers
    
    /// Process system audio buffer (extracted for error handling)
    private static nonisolated func handleSystemAudioBuffer(
        _ buffer: CMSampleBuffer,
        timestamp: CMTime,
        isAECEnabled: Bool,
        fileService: FileOutputService,
        transcriptionCoordinator: TranscriptionCoordinator,
        aecService: EchoCancellationService
    ) throws {
        // #region agent log
        let logPath = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
        let bufferValid = buffer.isValid
        let numSamples = CMSampleBufferGetNumSamples(buffer)
        let logData = try? JSONSerialization.data(withJSONObject: ["sessionId":"debug-session","runId":"initial","hypothesisId":"F,G","location":"RecordingController.swift:handleSystemAudioBuffer","message":"handleSystemAudioBuffer called","data":["bufferValid":bufferValid,"numSamples":numSamples],"timestamp":Date().timeIntervalSince1970*1000])
        if let data = logData, let json = String(data: data, encoding: .utf8) { (json + "\n").appendToDebugLog(atPath: logPath) }
        // #endregion
        
        // Store system audio for AEC reference (if AEC enabled)
        if isAECEnabled {
            if let systemSamples = EchoCancellationService.extractSamples(from: buffer) {
                aecService.storeSystemAudio(samples: systemSamples, timestamp: timestamp)
            }
        }
        
        // Save to file (always)
        fileService.appendAudioBuffer(buffer, type: .system)
        
        // Feed to transcription coordinator (handles buffering during model load)
        let samples = TranscriptionService.resampleToWhisperFormat(
            buffer,
            sourceSampleRate: 48000,
            sourceChannels: 2
        )
        // #region agent log
        let logData2 = try? JSONSerialization.data(withJSONObject: ["sessionId":"debug-session","runId":"initial","hypothesisId":"H","location":"RecordingController.swift:handleSystemAudioBuffer","message":"resampleToWhisperFormat result","data":["gotSamples":samples != nil,"sampleCount":samples?.count ?? 0],"timestamp":Date().timeIntervalSince1970*1000])
        if let data = logData2, let json = String(data: data, encoding: .utf8) { (json + "\n").appendToDebugLog(atPath: logPath) }
        // #endregion
        if let samples = samples {
            Task { @MainActor in
                transcriptionCoordinator.bufferSystemAudio(samples)
            }
        }
    }
    
    /// Process microphone audio buffer (extracted for error handling)
    private static nonisolated func handleMicrophoneAudioBuffer(
        _ buffer: CMSampleBuffer,
        timestamp: CMTime,
        isMicMuted: Bool,
        isAECEnabled: Bool,
        fileService: FileOutputService,
        transcriptionCoordinator: TranscriptionCoordinator,
        aecService: EchoCancellationService
    ) throws {
        // #region agent log
        let logPath = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
        let bufferValid = buffer.isValid
        let numSamples = CMSampleBufferGetNumSamples(buffer)
        let logData = try? JSONSerialization.data(withJSONObject: ["sessionId":"debug-session","runId":"mic-gap-debug","hypothesisId":"H1,H2","location":"RecordingController.swift:handleMicrophoneAudioBuffer","message":"handleMicrophoneAudioBuffer called","data":["bufferValid":bufferValid,"numSamples":numSamples,"isMicMuted":isMicMuted,"isAECEnabled":isAECEnabled],"timestamp":Date().timeIntervalSince1970*1000])
        if let data = logData, let json = String(data: data, encoding: .utf8) { (json + "\n").appendToDebugLog(atPath: logPath) }
        // #endregion
        
        // Extract microphone samples at 48kHz
        let micSamples48kHz = EchoCancellationService.extractSamples(from: buffer)
        // #region agent log
        let logData2 = try? JSONSerialization.data(withJSONObject: ["sessionId":"debug-session","runId":"initial","hypothesisId":"H","location":"RecordingController.swift:handleMicrophoneAudioBuffer","message":"extractSamples result","data":["gotSamples":micSamples48kHz != nil,"sampleCount":micSamples48kHz?.count ?? 0],"timestamp":Date().timeIntervalSince1970*1000])
        if let data = logData2, let json = String(data: data, encoding: .utf8) { (json + "\n").appendToDebugLog(atPath: logPath) }
        // #endregion
        guard let micSamples48kHz = micSamples48kHz else {
            // Fallback: save original buffer
            fileService.appendAudioBuffer(buffer, type: .microphone)
            return
        }
        
        // Apply AEC if enabled
        let processedSamples48kHz: [Float]
        if isAECEnabled {
            processedSamples48kHz = aecService.processMicrophoneAudio(
                microphoneSamples: micSamples48kHz,
                micTimestamp: timestamp
            )
            
            // #region agent log
            let logPath = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
            let origSampleCount = micSamples48kHz.count
            let aecSampleCount = processedSamples48kHz.count
            let logData4 = try? JSONSerialization.data(withJSONObject: ["sessionId":"debug-session","runId":"mic-gap-debug","hypothesisId":"H1","location":"RecordingController:handleMicrophoneAudioBuffer:AEC","message":"AEC processing result","data":["origSampleCount":origSampleCount,"aecSampleCount":aecSampleCount,"samplesDiff":origSampleCount-aecSampleCount],"timestamp":Date().timeIntervalSince1970*1000])
            if let data = logData4, let json = String(data: data, encoding: .utf8) { (json + "\n").appendToDebugLog(atPath: logPath) }
            // #endregion
            
            // Create CMSampleBuffer from processed samples for file output
            if let processedBuffer = EchoCancellationService.createSampleBuffer(
                from: processedSamples48kHz,
                timestamp: timestamp
            ) {
                // #region agent log
                let recreatedSamples = CMSampleBufferGetNumSamples(processedBuffer)
                let logData5 = try? JSONSerialization.data(withJSONObject: ["sessionId":"debug-session","runId":"mic-gap-debug","hypothesisId":"H1","location":"RecordingController:handleMicrophoneAudioBuffer:createBuffer","message":"Recreated buffer for file","data":["inputSamples":aecSampleCount,"outputSamples":recreatedSamples,"success":true],"timestamp":Date().timeIntervalSince1970*1000])
                if let data = logData5, let json = String(data: data, encoding: .utf8) { (json + "\n").appendToDebugLog(atPath: logPath) }
                // #endregion
                
                fileService.appendAudioBuffer(processedBuffer, type: .microphone)
            } else {
                // #region agent log
                let logData6 = try? JSONSerialization.data(withJSONObject: ["sessionId":"debug-session","runId":"mic-gap-debug","hypothesisId":"H1","location":"RecordingController:handleMicrophoneAudioBuffer:createBuffer","message":"createSampleBuffer FAILED - using fallback","data":["inputSamples":aecSampleCount],"timestamp":Date().timeIntervalSince1970*1000])
                if let data = logData6, let json = String(data: data, encoding: .utf8) { (json + "\n").appendToDebugLog(atPath: logPath) }
                // #endregion
                
                // Fallback: save original if conversion fails
                fileService.appendAudioBuffer(buffer, type: .microphone)
            }
        } else {
            processedSamples48kHz = micSamples48kHz
            // #region agent log
            let logPath = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
            let logData7 = try? JSONSerialization.data(withJSONObject: ["sessionId":"debug-session","runId":"mic-gap-debug","hypothesisId":"H1","location":"RecordingController:handleMicrophoneAudioBuffer:noAEC","message":"AEC disabled - using original buffer","data":["sampleCount":micSamples48kHz.count],"timestamp":Date().timeIntervalSince1970*1000])
            if let data = logData7, let json = String(data: data, encoding: .utf8) { (json + "\n").appendToDebugLog(atPath: logPath) }
            // #endregion
            
            // Save original buffer when AEC disabled
            fileService.appendAudioBuffer(buffer, type: .microphone)
        }
        
        // Skip microphone audio for transcription if muted
        if isMicMuted {
            return
        }
        
        // Feed to transcription coordinator (handles buffering during model load)
        // Use high-quality AVAudioConverter resampling (same as system audio) instead of linear interpolation
        let resampled = TranscriptionService.resampleSamples(
            samples: processedSamples48kHz,
            sourceSampleRate: 48000,
            sourceChannels: 1,  // Mic is mono
            targetSampleRate: 16000,
            targetChannels: 1,
            isInterleaved: false
        )
        // #region agent log
        // Calculate RMS for audio quality check
        let inputRMS = processedSamples48kHz.isEmpty ? 0 : sqrt(processedSamples48kHz.map { $0 * $0 }.reduce(0, +) / Float(processedSamples48kHz.count))
        let outputRMS = (resampled ?? []).isEmpty ? 0 : sqrt((resampled ?? []).map { $0 * $0 }.reduce(0, +) / Float((resampled ?? []).count))
        let logData3 = try? JSONSerialization.data(withJSONObject: ["sessionId":"debug-session","runId":"post-fix","hypothesisId":"H14,H15,H16","location":"RecordingController.swift:handleMicrophoneAudioBuffer","message":"High-quality resample result","data":["inputCount":processedSamples48kHz.count,"outputCount":resampled?.count ?? 0,"inputRMS":inputRMS,"outputRMS":outputRMS,"gotSamples":resampled != nil],"timestamp":Date().timeIntervalSince1970*1000])
        if let data = logData3, let json = String(data: data, encoding: .utf8) { (json + "\n").appendToDebugLog(atPath: logPath) }
        // #endregion
        if let resampled = resampled {
            Task { @MainActor in
                transcriptionCoordinator.bufferMicrophoneAudio(resampled)
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
        do {
            // Start file output FIRST
            session.outputDirectory = try fileOutputService.startWriting()
            
            // Configure microphone preference before starting capture
            // Pass selected mic device to AudioCaptureService for AVAudioEngine capture
            let selectedMicID = microphoneManager.selectedDeviceID
            await audioCaptureService.setMicrophoneDevice(selectedMicID)
            
            // CRITICAL: Ensure audio handlers are configured BEFORE starting capture
            // This fixes the race condition where handlers weren't set when capture started
            // #region agent log
            let logPath = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
            let logA = try? JSONSerialization.data(withJSONObject: ["sessionId":"debug-session","runId":"post-fix","hypothesisId":"K","location":"RecordingController.swift:startRecordingAsync","message":"BEFORE ensureAudioHandlersConfigured","data":[String:String](),"timestamp":Date().timeIntervalSince1970*1000])
            if let data = logA, let json = String(data: data, encoding: .utf8) { (json + "\n").appendToDebugLog(atPath: logPath) }
            // #endregion
            
            await ensureAudioHandlersConfigured()
            
            // #region agent log
            let logB = try? JSONSerialization.data(withJSONObject: ["sessionId":"debug-session","runId":"post-fix","hypothesisId":"K","location":"RecordingController.swift:startRecordingAsync","message":"AFTER ensureAudioHandlersConfigured, BEFORE startCapture","data":[String:String](),"timestamp":Date().timeIntervalSince1970*1000])
            if let data = logB, let json = String(data: data, encoding: .utf8) { (json + "\n").appendToDebugLog(atPath: logPath) }
            // #endregion
            
            // Start audio capture IMMEDIATELY (before model check)
            if let app = session.selectedApp {
                try await audioCaptureService.startCapture(forBundleIdentifier: app.bundleIdentifier)
            } else {
                try await audioCaptureService.startCapture()
            }
            
            // Audio is now flowing and being saved to disk ✅
            session.recordingStartTime = Date()
            session.state = .recording
            session.startDisplayTimer()
            echoCancellationService.reset()
            
            // Mark initialization as completing audio setup
            session.isInitializing = false
            
            // NOW try transcription (async, non-blocking)
            Task {
                await prepareTranscriptionAsync(for: session)
            }
            
        } catch let error as AudioCaptureService.CaptureError {
            handleCaptureError(error, for: session)
        } catch {
            handleGenericError(error, for: session)
        }
    }
    
    private func prepareTranscriptionAsync(for session: RecordingSession) async {
        // #region agent log
        let logPath = "/Users/dburkhardt/git-repos/muesli/.cursor/debug.log"
        let logEntry1 = try? JSONSerialization.data(withJSONObject: ["sessionId":"debug-session","runId":"initial","hypothesisId":"C","location":"RecordingController.swift:prepareTranscriptionAsync","message":"prepareTranscriptionAsync entry","data":["sessionId":session.id.uuidString],"timestamp":Date().timeIntervalSince1970*1000])
        if let data = logEntry1, let json = String(data: data, encoding: .utf8) { (json + "\n").appendToDebugLog(atPath: logPath) }
        // #endregion
        
        // Set modelLoading indicator
        session.isModelLoading = true
        
        transcriptionCoordinator.resetForNewRecording()
        let modelState = await transcriptionCoordinator.prepareModel()
        
        // #region agent log
        let stateStr: String
        switch modelState {
        case .notAvailable: stateStr = "notAvailable"
        case .loading: stateStr = "loading"
        case .ready: stateStr = "ready"
        case .failed(let e): stateStr = "failed: \(e.localizedDescription)"
        }
        let logEntry2 = try? JSONSerialization.data(withJSONObject: ["sessionId":"debug-session","runId":"initial","hypothesisId":"C","location":"RecordingController.swift:prepareTranscriptionAsync","message":"prepareModel returned","data":["modelState":stateStr],"timestamp":Date().timeIntervalSince1970*1000])
        if let data = logEntry2, let json = String(data: data, encoding: .utf8) { (json + "\n").appendToDebugLog(atPath: logPath) }
        // #endregion
        
        switch modelState {
        case .notAvailable:
            session.isModelLoading = false
            session.isRecordingOnly = true
            // Continue recording without transcription
            
        case .loading:
            // Keep indicator showing, coordinator buffers audio
            break
            
        case .ready:
            session.isModelLoading = false
            transcriptionCoordinator.setTranscriptHandler { [weak session] segment in
                Task { @MainActor in
                    session?.appendTranscriptSegment(segment)
                }
            }
            // #region agent log
            let logEntry3 = try? JSONSerialization.data(withJSONObject: ["sessionId":"debug-session","runId":"initial","hypothesisId":"B,C","location":"RecordingController.swift:prepareTranscriptionAsync","message":"Calling startTranscription","data":["recordingStartTime":session.recordingStartTime?.timeIntervalSince1970 ?? 0],"timestamp":Date().timeIntervalSince1970*1000])
            if let data = logEntry3, let json = String(data: data, encoding: .utf8) { (json + "\n").appendToDebugLog(atPath: logPath) }
            // #endregion
            transcriptionCoordinator.startTranscription(recordingStartTime: session.recordingStartTime ?? Date())
            
        case .failed(let error):
            session.isModelLoading = false
            session.isRecordingOnly = true
            // Log error but continue recording audio
            print("[RecordingController] Model loading failed: \(error), continuing audio-only recording")
        }
    }
    
    private func handleCaptureError(_ error: AudioCaptureService.CaptureError, for session: RecordingSession) {
        let muesliError: MuesliError
        switch error {
        case .noContentToCapture:
            muesliError = .noAudioContent
        case .permissionDenied, .streamStartFailed:
            muesliError = .screenRecordingDenied
        default:
            muesliError = .captureStartFailed(underlying: error)
        }
        
        // Add context for specific cases
        if case .noContentToCapture = error, let app = session.selectedApp {
            session.showErrorMessage("Could not find \(app.name). Make sure it's running and has a window open.")
        } else {
            session.showError(muesliError)
        }
        cleanupFailedSession(session)
    }
    
    private func handleGenericError(_ error: Error, for session: RecordingSession) {
        let errorMsg = error.localizedDescription
        
        let muesliError: MuesliError
        if errorMsg.contains("TCC") || errorMsg.contains("declined") || errorMsg.contains("permission") {
            muesliError = .screenRecordingDenied
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
            
            // Stop file writing and get output directory
            let directory: URL
            do {
                directory = try await fileOutputService.stopWriting()
            } catch {
                session.showError(.outputDirectoryCreationFailed)
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
            
        } catch {
            session.showError(.transcriptSaveFailed(underlying: error))
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
            session.showError(.postProcessingFailed(underlying: error))
        }
    }
    
    // MARK: - Model Error Handling
    
    func startRecordingWithoutTranscription() {
        guard let session = sessionPendingModelDecision else { return }
        sessionPendingModelDecision = nil
        showModelErrorAlert = false
        session.showError(.whisperKitNotInitialized)
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
            
            // Stop file writing and get output directory
            let directory: URL
            do {
                directory = try await fileOutputService.stopWriting()
            } catch {
                session.state = .completed
                session.showError(.outputDirectoryCreationFailed)
                activeSession = nil
                resetMuteState()
                return
            }
            
            session.outputDirectory = directory
            
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
            
        } catch {
            session.showError(.transcriptSaveFailed(underlying: error))
        }
        
        session.state = .completed
        // Show success message with interruption reason
        if let reason = session.interruptionReason {
            session.showErrorMessage("Recording saved. \(reason)")
        } else {
            session.showErrorMessage("Recording saved. The stream was interrupted.")
        }
        
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
            // Reset retry budget for a fresh recording session
            transcriptionCoordinator.resetForNewRecording()
            
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
            
            // Notify ViewModel that session started
            onSessionStarted?(session)
            onSplitViewVisibilityChanged?(true)
            
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
            
            // Pass selected mic device to AudioCaptureService for AVAudioEngine capture
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
}
