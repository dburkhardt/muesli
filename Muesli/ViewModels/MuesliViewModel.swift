import Foundation
import SwiftUI
import ScreenCaptureKit
import CoreMedia
import ServiceManagement

/// Main ViewModel for the Muesli app
/// Owns app-level state (permissions, detected apps) and services
/// Recording sessions are managed separately via RecordingSession objects
@Observable
@MainActor
final class MuesliViewModel {
    
    // MARK: - App Detection
    
    var availableMeetingApps: [MeetingAppDetector.DetectedApp] = []
    
    // MARK: - Permissions
    
    var hasScreenRecordingPermission: Bool = false
    var hasMicrophonePermission: Bool = false
    
    /// Whether microphone permission was explicitly denied
    var isMicrophonePermissionDenied: Bool {
        permissionManager.isMicrophonePermissionDenied
    }
    
    // MARK: - Onboarding
    
    var hasCompletedOnboarding: Bool = false
    
    private static let onboardingCompletedKey = "hasCompletedOnboarding"
    
    // MARK: - Model Management (shared instance)
    
    let modelManager = ModelManager()
    
    /// LLM Manager for transcript stitching (optional enhancement)
    let llmManager = LLMManager()
    
    /// Transcript refinement service for post-meeting cleanup
    private(set) var refinementService: TranscriptRefinementService!
    
    /// Convenience accessor for the active model path
    var modelPath: URL? {
        modelManager.modelPath
    }
    
    // MARK: - Services
    
    private let audioCaptureService = AudioCaptureService()
    private let fileOutputService = FileOutputService()
    private let transcriptionService = TranscriptionService()
    private let meetingAppDetector = MeetingAppDetector()
    private let permissionManager = PermissionManager()
    let microphoneManager = MicrophoneManager()
    private let meetingHistoryService = MeetingHistoryService()
    
    // MARK: - Transcription State
    
    var isTranscriptionInitialized: Bool = false
    
    /// Transcription mode: live (real-time) or post-processing (after recording)
    var transcriptionMode: TranscriptionService.TranscriptionMode {
        get {
            let rawValue = UserDefaults.standard.string(forKey: "transcriptionMode") ?? "live"
            return TranscriptionService.TranscriptionMode(rawValue: rawValue) ?? .live
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "transcriptionMode")
            transcriptionService.setTranscriptionMode(newValue)
        }
    }
    
    // MARK: - Active Session Tracking
    
    /// The currently recording session (only one can record at a time)
    private(set) var activeSession: RecordingSession?
    
    /// Alias for activeSession (for clarity in new UI)
    var activeRecordingSession: RecordingSession? {
        activeSession
    }
    
    /// Microphone mute state (for synchronous access from audio callback)
    nonisolated(unsafe) private var isMicrophoneMuted: Bool = false
    
    // MARK: - Meeting History
    
    /// All discovered meeting recordings
    var meetingHistory: [MeetingHistoryItem] = []
    
    /// Meeting history grouped by date
    var groupedHistory: [MeetingHistoryGroup] = []
    
    /// Currently selected meeting for viewing
    var selectedMeeting: MeetingHistoryItem?
    
    /// Set of selected meeting IDs (for multi-select)
    var selectedMeetingIDs: Set<UUID> = []
    
    /// Meeting to show in completed meeting window (when recording is active)
    var completedMeetingWindowItem: MeetingHistoryItem?
    
    /// Whether to show delete confirmation dialog
    var showDeleteConfirmation: Bool = false
    
    /// Meetings pending deletion (after confirmation)
    var meetingsPendingDeletion: [MeetingHistoryItem] = []
    
    /// Whether the split view (sidebar + detail) should be visible
    var isSplitViewVisible: Bool = false
    
    /// Whether to show the start recording sheet
    var showStartRecordingSheet: Bool = false
    
    /// Whether to show the meeting title prompt sheet
    var showTitlePromptSheet: Bool = false
    
    /// Session pending stop (waiting for title input)
    var pendingStopSession: RecordingSession?
    
    // MARK: - Refinement State
    
    /// Whether to show the refinement progress sheet
    var showRefineSheet: Bool = false
    
    /// Whether to show the post-meeting refinement prompt
    var showRefinementPrompt: Bool = false
    
    /// Meeting being refined (for UI state)
    var meetingBeingRefined: MeetingHistoryItem?
    
    /// Cancellation flag for refinement
    private var refinementCancelled: Bool = false
    
    /// Whether to show the About window
    var showAboutWindow: Bool = false
    
    // MARK: - Preferences
    
    private static let outputDirectoryKey = "outputDirectory"
    private static let launchAtLoginKey = "launchAtLogin"
    
    /// Output directory for recordings
    var outputDirectory: URL {
        get {
            if let savedPath = UserDefaults.standard.string(forKey: Self.outputDirectoryKey) {
                return URL(fileURLWithPath: savedPath)
            }
            return Self.defaultOutputDirectory
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: Self.outputDirectoryKey)
            fileOutputService.setOutputDirectory(newValue)
        }
    }
    
    /// Default output directory: ~/Documents/Meeting Transcripts
    static var defaultOutputDirectory: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsPath.appendingPathComponent("Meeting Transcripts")
    }
    
    /// Set the output directory
    func setOutputDirectory(_ url: URL) {
        outputDirectory = url
    }
    
    /// Reset output directory to default
    func resetOutputDirectory() {
        UserDefaults.standard.removeObject(forKey: Self.outputDirectoryKey)
        fileOutputService.setOutputDirectory(Self.defaultOutputDirectory)
    }
    
    /// Whether to launch at login
    var launchAtLogin: Bool {
        get {
            if #available(macOS 13.0, *) {
                return SMAppService.mainApp.status == .enabled
            }
            return UserDefaults.standard.bool(forKey: Self.launchAtLoginKey)
        }
        set {
            if #available(macOS 13.0, *) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    print("[MuesliViewModel] Failed to set launch at login: \(error)")
                }
            }
            UserDefaults.standard.set(newValue, forKey: Self.launchAtLoginKey)
        }
    }
    
    /// Set launch at login
    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled
    }
    
    // MARK: - Recording Navigation State
    
    /// True when there's an active recording AND user is viewing a past meeting (not the live recording)
    var isViewingPastMeetingWhileRecording: Bool {
        activeRecordingSession != nil && selectedMeeting != nil
    }
    
    /// Return to viewing the live recording (clear selected past meeting)
    func returnToLiveRecording() {
        selectedMeeting = nil
        selectedMeetingIDs.removeAll()
    }
    
    // MARK: - Initialization
    
    init() {
        // Initialize refinement service
        refinementService = TranscriptRefinementService(llmManager: llmManager)
        
        // Load onboarding state
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey)
        
        // Check initial permission status
        refreshPermissions()
        
        // Set up audio buffer handler - fork to both file output and transcription
        let fileService = fileOutputService
        let transcriptService = transcriptionService
        Task {
            await audioCaptureService.setBufferHandler { [weak self] buffer, type in
                let isMicMuted = self?.isMicrophoneMuted ?? false // Synchronous check
                
                // Save to file (always)
                fileService.appendAudioBuffer(buffer, type: type)
                
                // Only feed to transcription in live mode
                if transcriptService.transcriptionMode == .live {
                    // Convert and feed to transcription based on audio type
                    switch type {
                    case .system:
                        // System audio: 48kHz stereo Float32 -> 16kHz mono Float32
                        if let samples = TranscriptionService.resampleToWhisperFormat(
                            buffer,
                            sourceSampleRate: 48000,
                            sourceChannels: 2
                        ) {
                            transcriptService.appendSystemAudio(samples)
                        }
                    case .microphone:
                        // Skip transcription if microphone is muted
                        if isMicMuted {
                            return
                        }
                        // Microphone audio: 16kHz stereo Int16 -> 16kHz mono Float32
                        // No resampling needed, just format conversion
                        if let samples = TranscriptionService.convertInt16ToWhisperFormat(buffer) {
                            transcriptService.appendMicrophoneAudio(samples)
                        }
                    }
                }
            }
            
            // Set up stream interruption handler (e.g., captured app quits)
            await audioCaptureService.setInterruptedHandler { [weak self] error in
                Task { @MainActor in
                    self?.handleCaptureInterrupted(error: error)
                }
            }
            
            // Set up audio level handler for microphone indicator
            await audioCaptureService.setLevelHandler { [weak self] level, type in
                Task { @MainActor in
                    self?.updateAudioLevel(level, type: type)
                }
            }
        }
        
        // Set initial transcription mode
        transcriptionService.setTranscriptionMode(transcriptionMode)
        
        // Load available meeting apps
        Task {
            await refreshMeetingApps()
        }
        
        // Load meeting history
        loadMeetingHistory()
    }
    
    // MARK: - Session Management
    
    /// Create a new recording session
    func createSession() -> RecordingSession {
        return RecordingSession()
    }
    
    /// Update audio level for the active session
    private func updateAudioLevel(_ level: Float, type: AudioCaptureService.AudioType) {
        guard let session = activeSession else { return }
        
        switch type {
        case .microphone:
            session.microphoneLevel = level
        case .system:
            session.systemAudioLevel = level
        }
    }
    
    // MARK: - Permission Management
    
    func refreshPermissions() {
        hasScreenRecordingPermission = permissionManager.hasScreenRecordingPermission
        hasMicrophonePermission = permissionManager.hasMicrophonePermission
    }
    
    /// Async permission refresh that uses SCShareableContent for reliable screen recording detection
    func refreshPermissionsAsync() async {
        // Use async check for screen recording (reliable with ad-hoc signing)
        let screenResult = await permissionManager.checkScreenRecordingPermissionAsync()
        hasScreenRecordingPermission = screenResult
        hasMicrophonePermission = permissionManager.hasMicrophonePermission
    }
    
    func requestScreenRecordingPermission() {
        permissionManager.requestScreenRecordingPermission()
    }
    
    func openScreenRecordingSettings() {
        permissionManager.openScreenRecordingSettings()
    }
    
    func requestMicrophonePermission() async {
        hasMicrophonePermission = await permissionManager.requestMicrophonePermission()
    }
    
    func openMicrophoneSettings() {
        permissionManager.openMicrophoneSettings()
    }
    
    // MARK: - Menu Actions
    
    /// Show the About window
    func showAbout() {
        showAboutWindow = true
    }
    
    /// Open the main window
    func openMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Find existing main window or create it
        if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Window doesn't exist yet - trigger window creation via notification
            // The Window scene will handle creation
            NotificationCenter.default.post(name: NSNotification.Name("OpenMainWindow"), object: nil)
            // Also try direct approach after a small delay
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
    }
    
    /// Start a new recording
    func startNewRecording() {
        quickStartRecording()
        openMainWindow()
    }
    
    // MARK: - Onboarding
    
    func completeOnboarding() {
        // Model path is now managed by ModelManager, we just mark onboarding as done
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
    }
    
    func resetOnboarding() {
        hasCompletedOnboarding = false
        modelManager.reset()
        UserDefaults.standard.removeObject(forKey: Self.onboardingCompletedKey)
    }
    
    // MARK: - Meeting App Detection
    
    func refreshMeetingApps() async {
        availableMeetingApps = await meetingAppDetector.detectMeetingApps()
    }
    
    // MARK: - Recording Actions
    
    /// Quick start recording with all system audio (no app selection needed)
    /// Creates a new session and immediately starts recording
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
        transcriptionMode = .live
        
        // Start recording
        startRecording(for: session)
        
        // Transition to split view
        isSplitViewVisible = true
    }
    
    /// Start recording for a session
    /// - Parameter session: The session to start recording for
    /// If session.selectedApp is nil, captures all system audio
    func startRecording(for session: RecordingSession) {
        // Only one session can record at a time
        guard activeSession == nil else {
            session.showErrorMessage("Another recording is already in progress.")
            return
        }
        
        // Set activeSession immediately so UI shows recording view right away
        // (will be cleared if async setup fails)
        activeSession = session
        isMicrophoneMuted = session.isMicrophoneMuted // Sync mute state
        
        Task {
            await startRecordingAsync(for: session)
        }
    }
    
    private func startRecordingAsync(for session: RecordingSession) async {
        do {
            // Validate model path BEFORE attempting initialization (fail fast)
            guard let validModelPath = modelPath else {
                session.showErrorMessage("No transcription model configured. Please download a model first.")
                session.state = .idle
                activeSession = nil  // Clear since setup failed
                return
            }
            
            // Check that the model directory and config.json exist
            let configPath = validModelPath.appendingPathComponent("config.json")
            guard FileManager.default.fileExists(atPath: configPath.path) else {
                session.showErrorMessage("Transcription model is incomplete or corrupted. Please re-download the model.")
                session.state = .idle
                activeSession = nil  // Clear since setup failed
                return
            }
            
            // Initialize transcription service if needed
            if !isTranscriptionInitialized {
                try await transcriptionService.initialize(modelPath: validModelPath)
                isTranscriptionInitialized = true
            }
            
            // Set up transcript handler
            transcriptionService.setTranscriptHandler { [weak session] segment in
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
            
            // Start audio capture - either filtered to a specific app or all system audio
            if let app = session.selectedApp {
                try await audioCaptureService.startCapture(forBundleIdentifier: app.bundleIdentifier)
            } else {
                // Capture all system audio (no app filter)
                try await audioCaptureService.startCapture()
            }
            
            // Update session state on success
            session.state = .recording
            session.recordingStartTime = Date()
            session.transcriptText = ""
            session.startDisplayTimer()
            
            // Start transcription
            transcriptionService.startTranscription(recordingStartTime: session.recordingStartTime ?? Date())
            
        } catch let error as AudioCaptureService.CaptureError {
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
            session.state = .idle
            activeSession = nil  // Clear since setup failed
            
            if fileOutputService.isWriting {
                _ = try? await fileOutputService.stopWriting()
            }
        } catch {
            let errorMsg = error.localizedDescription
            
            if errorMsg.contains("TCC") || errorMsg.contains("declined") || errorMsg.contains("permission") {
                session.showErrorMessage("Please grant Screen Recording permission and try again.")
            } else {
                session.showErrorMessage("Failed to start recording: \(errorMsg)")
            }
            session.state = .idle
            activeSession = nil  // Clear since setup failed
            
            if fileOutputService.isWriting {
                _ = try? await fileOutputService.stopWriting()
            }
        }
    }
    
    /// Stop recording for a session
    /// - Parameter session: The session to stop recording for
    /// If title is empty, shows a prompt sheet first
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
    
    /// Called after title prompt is confirmed or skipped
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
            // Stop audio capture
            try await audioCaptureService.stopCapture()
            
            // Stop transcription without processing remaining audio
            await transcriptionService.stopTranscription()
            
            // Stop file writing and get directory (will be deleted)
            let directory = try? await fileOutputService.stopWriting()
            
            // Delete the output directory if it exists
            if let directory = directory {
                try? FileManager.default.removeItem(at: directory)
            }
            
        } catch {
            // Errors during discard can be ignored
        }
        
        // Clear session without adding to history
        session.state = .idle
        activeSession = nil
    }
    
    /// Actually perform the stop recording operation
    private func performStopRecording(for session: RecordingSession) {
        Task {
            await stopRecordingAsync(for: session)
        }
    }
    
    private func stopRecordingAsync(for session: RecordingSession) async {
        session.state = .stopping
        session.stopDisplayTimer()
        
        do {
            // Stop audio capture
            try await audioCaptureService.stopCapture()
            
            // Stop transcription and process remaining audio (for live mode)
            await transcriptionService.stopTranscription()
            
            // Finalize file output
            guard let directory = try? await fileOutputService.stopWriting() else {
                session.state = .completed
                activeSession = nil
                return
            }
            
            session.outputDirectory = directory
            
            // Handle post-processing transcription if needed
            if transcriptionMode == .postProcessing {
                // Show processing state
                session.transcriptText = "Processing transcript..."
                
                // Get audio file URLs
                let systemAudioURL = directory.appendingPathComponent("audio.caf")
                let micAudioURL = directory.appendingPathComponent("microphone.caf")
                
                // Transcribe in post-processing mode
                do {
                    session.transcriptText = "" // Clear processing message
                    try await transcriptionService.transcribePostProcessing(
                        systemAudioURL: FileManager.default.fileExists(atPath: systemAudioURL.path) ? systemAudioURL : nil,
                        micAudioURL: FileManager.default.fileExists(atPath: micAudioURL.path) ? micAudioURL : nil,
                        startTime: session.recordingStartTime ?? Date()
                    )
                } catch {
                    session.showErrorMessage("Post-processing transcription failed: \(error.localizedDescription)")
                }
            }
            
            // Finalize transcript processing and save with speaker labels (block format)
            session.finalizeTranscript()
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
        
        // Refresh meeting history to include the new recording
        refreshMeetingHistory()
        
        // Select the newly completed meeting
        if let directory = session.outputDirectory {
            selectedMeeting = meetingHistory.first { $0.directory == directory }
            // Clear activeSession after selecting the meeting
            activeSession = nil
            
            // Show post-meeting refinement prompt if LLM is available
            if canRefineTranscripts && selectedMeeting != nil {
                // Small delay to let the UI settle before showing prompt
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                    showPostMeetingRefinementPrompt()
                }
            }
        } else {
            activeSession = nil
        }
    }
    
    // MARK: - Capture Interruption Handling
    
    /// Handle when the audio capture stream is interrupted (e.g., captured app quits)
    private func handleCaptureInterrupted(error: Error?) {
        guard let session = activeSession else { return }
        
        // Mark session as interrupted
        session.wasInterrupted = true
        session.interruptionReason = "The captured app was closed"
        
        // Gracefully stop and save
        Task {
            await stopRecordingAfterInterruption(for: session)
        }
    }
    
    /// Stop recording after an interruption (stream already stopped)
    private func stopRecordingAfterInterruption(for session: RecordingSession) async {
        session.state = .stopping
        session.stopDisplayTimer()
        
        do {
            // Note: We don't call audioCaptureService.stopCapture() here because the stream already stopped
            
            // Stop transcription and process remaining audio (for live mode)
            await transcriptionService.stopTranscription()
            
            // Finalize file output
            guard let directory = try? await fileOutputService.stopWriting() else {
                session.state = .completed
                session.showErrorMessage("Recording was interrupted: \(session.interruptionReason ?? "Unknown reason")")
                activeSession = nil
                return
            }
            
            session.outputDirectory = directory
            
            // Handle post-processing transcription if needed
            if transcriptionMode == .postProcessing {
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
                    session.showErrorMessage("Post-processing failed: \(error.localizedDescription)")
                }
            }
            
            // Finalize transcript processing and save with speaker labels (block format)
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
        
        // Mark session as completed and show interruption message
        session.state = .completed
        session.showErrorMessage("Recording saved. \(session.interruptionReason ?? "The stream was interrupted.")")
        
        // Refresh meeting history
        refreshMeetingHistory()
        
        // Select the saved meeting
        if let directory = session.outputDirectory {
            selectedMeeting = meetingHistory.first { $0.directory == directory }
            activeSession = nil
        } else {
            activeSession = nil
        }
    }
    
    /// Re-transcribe a completed recording with post-processing mode
    /// - Parameter session: The session to re-transcribe
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
        
        // Validate model path
        guard let validModelPath = modelPath else {
            session.showErrorMessage("No transcription model configured.")
            return
        }
        
        let configPath = validModelPath.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            session.showErrorMessage("Transcription model is incomplete or corrupted.")
            return
        }
        
        // Set retranscribing state
        session.isRetranscribing = true
        
        // Initialize transcription service if needed
        if !isTranscriptionInitialized {
            do {
                try await transcriptionService.initialize(modelPath: validModelPath)
                isTranscriptionInitialized = true
            } catch {
                session.isRetranscribing = false
                session.showErrorMessage("Failed to initialize transcription: \(error.localizedDescription)")
                return
            }
        }
        
        // Set transcription mode to post-processing temporarily
        let previousMode = transcriptionService.transcriptionMode
        transcriptionService.setTranscriptionMode(.postProcessing)
        
        // Set up transcript handler to process segments through the block pipeline
        transcriptionService.setTranscriptHandler { [weak session] segment in
            Task { @MainActor in
                guard let session = session else { return }
                session.appendTranscriptSegment(segment)
            }
        }
        
        // Get audio file URLs
        let systemAudioURL = directory.appendingPathComponent("audio.caf")
        let micAudioURL = directory.appendingPathComponent("microphone.caf")
        
        // Transcribe with post-processing
        do {
            // Clear existing transcript and blocks
            session.resetTranscript()
            
            try await transcriptionService.transcribePostProcessing(
                systemAudioURL: FileManager.default.fileExists(atPath: systemAudioURL.path) ? systemAudioURL : nil,
                micAudioURL: FileManager.default.fileExists(atPath: micAudioURL.path) ? micAudioURL : nil,
                startTime: session.recordingStartTime ?? Date()
            )
            
            // Finalize transcript processing
            session.finalizeTranscript()
            
            // Save updated transcript to file (block format)
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
        
        // Restore previous mode
        transcriptionService.setTranscriptionMode(previousMode)
        
        // Clear retranscribing state
        session.isRetranscribing = false
    }
    
    // MARK: - Meeting History Management
    
    /// Load meeting history from disk
    func loadMeetingHistory() {
        meetingHistory = meetingHistoryService.discoverMeetings()
        groupedHistory = groupMeetingsByDate(meetingHistory)
    }
    
    /// Refresh meeting history (call after recording completes)
    func refreshMeetingHistory() {
        loadMeetingHistory()
    }
    
    /// Group meetings by date: by day for last week, by month for older
    /// - Parameter meetings: Array of meetings to group
    /// - Returns: Array of groups, sorted newest first
    func groupMeetingsByDate(_ meetings: [MeetingHistoryItem]) -> [MeetingHistoryGroup] {
        guard !meetings.isEmpty else { return [] }
        
        let calendar = Calendar.current
        let now = Date()
        
        // Separate meetings into last 7 days and older
        var lastWeekMeetings: [MeetingHistoryItem] = []
        var olderMeetings: [MeetingHistoryItem] = []
        
        for meeting in meetings {
            let daysSince = calendar.dateComponents([.day], from: meeting.date, to: now).day ?? 0
            if daysSince < 7 {
                lastWeekMeetings.append(meeting)
            } else {
                olderMeetings.append(meeting)
            }
        }
        
        var groups: [MeetingHistoryGroup] = []
        
        // Group last week by day
        let lastWeekGroups = Dictionary(grouping: lastWeekMeetings) { meeting -> Date in
            calendar.startOfDay(for: meeting.date)
        }
        
        for (dayStart, dayMeetings) in lastWeekGroups.sorted(by: { $0.key > $1.key }) {
            let label = formatDayLabel(dayStart, relativeTo: now)
            groups.append(MeetingHistoryGroup(
                date: dayStart,
                label: label,
                meetings: dayMeetings.sorted { $0.date > $1.date }
            ))
        }
        
        // Group older meetings by month
        let monthGroups = Dictionary(grouping: olderMeetings) { meeting -> Date in
            let components = calendar.dateComponents([.year, .month], from: meeting.date)
            return calendar.date(from: components) ?? meeting.date
        }
        
        for (monthStart, monthMeetings) in monthGroups.sorted(by: { $0.key > $1.key }) {
            let label = formatMonthLabel(monthStart)
            groups.append(MeetingHistoryGroup(
                date: monthStart,
                label: label,
                meetings: monthMeetings.sorted { $0.date > $1.date }
            ))
        }
        
        return groups
    }
    
    /// Format a day label (Today, Yesterday, or date)
    private func formatDayLabel(_ date: Date, relativeTo now: Date) -> String {
        let calendar = Calendar.current
        
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d, yyyy"
            return formatter.string(from: date)
        }
    }
    
    /// Format a month label
    private func formatMonthLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }
    
    /// Load transcript for a meeting (lazy-load)
    func loadTranscript(for meeting: MeetingHistoryItem) {
        guard meeting.transcript == nil else { return }
        
        // Load plain text transcript
        meeting.transcript = meetingHistoryService.loadTranscript(for: meeting)
        
        // Also try to load block-based transcript (new format)
        if meeting.transcriptBlocks == nil {
            meeting.transcriptBlocks = meetingHistoryService.loadTranscriptBlocks(for: meeting)
        }
    }
    
    // MARK: - Meeting Selection (Multi-select)
    
    /// Toggle selection of a meeting
    func toggleMeetingSelection(_ meeting: MeetingHistoryItem, extendSelection: Bool = false) {
        if extendSelection {
            // Cmd+click: toggle individual selection
            if selectedMeetingIDs.contains(meeting.id) {
                selectedMeetingIDs.remove(meeting.id)
            } else {
                selectedMeetingIDs.insert(meeting.id)
            }
        } else {
            // Regular click: single selection
            selectedMeetingIDs = [meeting.id]
        }
        
        // Update selectedMeeting for detail view
        if selectedMeetingIDs.count == 1, let id = selectedMeetingIDs.first {
            selectedMeeting = meetingHistory.first { $0.id == id }
            if let meeting = selectedMeeting {
                loadTranscript(for: meeting)
            }
        } else {
            selectedMeeting = nil
        }
    }
    
    /// Select all meetings in a range (for Shift+click)
    func selectMeetingsInRange(to meeting: MeetingHistoryItem) {
        guard let lastSelectedID = selectedMeetingIDs.first,
              let lastIndex = meetingHistory.firstIndex(where: { $0.id == lastSelectedID }),
              let targetIndex = meetingHistory.firstIndex(where: { $0.id == meeting.id }) else {
            toggleMeetingSelection(meeting)
            return
        }
        
        let range = min(lastIndex, targetIndex)...max(lastIndex, targetIndex)
        for i in range {
            selectedMeetingIDs.insert(meetingHistory[i].id)
        }
    }
    
    /// Clear all selections
    func clearSelection() {
        selectedMeetingIDs.removeAll()
        selectedMeeting = nil
    }
    
    /// Get selected meetings
    var selectedMeetings: [MeetingHistoryItem] {
        meetingHistory.filter { selectedMeetingIDs.contains($0.id) }
    }
    
    // MARK: - Meeting Deletion
    
    /// Request deletion of selected meetings (shows confirmation)
    func requestDeleteSelectedMeetings() {
        let meetings = selectedMeetings
        guard !meetings.isEmpty else { return }
        meetingsPendingDeletion = meetings
        showDeleteConfirmation = true
    }
    
    /// Request deletion of a specific meeting (shows confirmation)
    func requestDeleteMeeting(_ meeting: MeetingHistoryItem) {
        meetingsPendingDeletion = [meeting]
        showDeleteConfirmation = true
    }
    
    /// Confirm and execute deletion
    func confirmDeleteMeetings() {
        let meetingsToDelete = meetingsPendingDeletion
        meetingsPendingDeletion = []
        showDeleteConfirmation = false
        
        // Delete from disk
        for meeting in meetingsToDelete {
            deleteMeetingFromDisk(meeting)
        }
        
        // Clear selection if deleted meetings were selected
        for meeting in meetingsToDelete {
            selectedMeetingIDs.remove(meeting.id)
            if selectedMeeting?.id == meeting.id {
                selectedMeeting = nil
            }
        }
        
        // Refresh history
        refreshMeetingHistory()
    }
    
    /// Cancel deletion
    func cancelDeleteMeetings() {
        meetingsPendingDeletion = []
        showDeleteConfirmation = false
    }
    
    /// Delete a meeting's folder from disk
    private func deleteMeetingFromDisk(_ meeting: MeetingHistoryItem) {
        let fileManager = FileManager.default
        do {
            try fileManager.removeItem(at: meeting.directory)
        } catch {
            print("[MuesliViewModel] Failed to delete meeting: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Transcript Refinement
    
    /// Check if refinement is available (LLM model downloaded)
    var canRefineTranscripts: Bool {
        llmManager.hasModel && llmManager.isLLMStitchingEnabled
    }
    
    /// Start refining a meeting's transcript
    func refineTranscript(for meeting: MeetingHistoryItem) {
        guard canRefineTranscripts else { return }
        guard !refinementService.isRefining else { return }
        
        meetingBeingRefined = meeting
        showRefineSheet = true
        refinementCancelled = false
        
        Task {
            await refineTranscriptAsync(for: meeting)
        }
    }
    
    /// Async refinement implementation
    private func refineTranscriptAsync(for meeting: MeetingHistoryItem) async {
        // Ensure model is loaded
        if llmManager.modelContainer == nil, let activeModel = llmManager.activeModel {
            do {
                try await llmManager.loadModel(activeModel)
            } catch {
                refinementService.errorMessage = "Failed to load LLM model: \(error.localizedDescription)"
                return
            }
        }
        
        do {
            // Refine based on available transcript format
            if let blocks = meeting.transcriptBlocks, !blocks.isEmpty {
                // Refine block-based transcript
                let refinedBlocks = try await refinementService.refineTranscript(blocks)
                
                guard !refinementCancelled else { return }
                
                // Update meeting with refined blocks
                meeting.transcriptBlocks = refinedBlocks
                
                // Also update plain text version
                meeting.transcript = refinedBlocks.map { block in
                    "[\(block.speaker.rawValue)] \(block.text)"
                }.joined(separator: "\n\n")
                
                // Save to disk
                saveRefinedTranscript(meeting, blocks: refinedBlocks)
                
                // Dismiss sheet after successful completion
                await MainActor.run {
                    dismissRefinementSheet()
                }
                
            } else if let text = meeting.transcript, !text.isEmpty {
                // Refine plain text transcript
                let refinedText = try await refinementService.refineTranscript(text)
                
                guard !refinementCancelled else { return }
                
                // Update meeting
                meeting.transcript = refinedText
                
                // Save to disk
                saveRefinedTranscript(meeting, text: refinedText)
                
                // Dismiss sheet after successful completion
                await MainActor.run {
                    dismissRefinementSheet()
                }
            }
            
        } catch {
            // Error is already set in refinementService
            print("[MuesliViewModel] Refinement failed: \(error)")
            // Keep sheet open to show error
        }
    }
    
    /// Save refined block-based transcript to disk
    private func saveRefinedTranscript(_ meeting: MeetingHistoryItem, blocks: [TranscriptBlock]) {
        do {
            try fileOutputService.saveTranscriptBlocks(
                blocks,
                title: meeting.title,
                date: meeting.date,
                to: meeting.directory
            )
        } catch {
            print("[MuesliViewModel] Failed to save refined transcript: \(error)")
        }
    }
    
    /// Save refined plain text transcript to disk
    private func saveRefinedTranscript(_ meeting: MeetingHistoryItem, text: String) {
        let transcriptURL = meeting.directory.appendingPathComponent("transcript.md")
        do {
            // Build markdown content
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .full
            dateFormatter.timeStyle = .short
            
            let content = """
            # \(meeting.title)
            
            **Date:** \(dateFormatter.string(from: meeting.date))
            
            ---
            
            \(text)
            """
            
            try content.write(to: transcriptURL, atomically: true, encoding: .utf8)
        } catch {
            print("[MuesliViewModel] Failed to save refined transcript: \(error)")
        }
    }
    
    /// Cancel ongoing refinement
    func cancelRefinement() {
        refinementCancelled = true
        showRefineSheet = false
        meetingBeingRefined = nil
    }
    
    /// Dismiss refinement sheet (after completion or error)
    func dismissRefinementSheet() {
        showRefineSheet = false
        meetingBeingRefined = nil
    }
    
    /// Show post-meeting refinement prompt
    func showPostMeetingRefinementPrompt() {
        guard canRefineTranscripts else { return }
        showRefinementPrompt = true
    }
    
    /// Skip refinement from post-meeting prompt
    func skipRefinement() {
        showRefinementPrompt = false
    }
    
    /// Accept refinement from post-meeting prompt
    func acceptRefinement() {
        showRefinementPrompt = false
        if let meeting = selectedMeeting {
            refineTranscript(for: meeting)
        }
    }
    
    // MARK: - Microphone Mute
    
    /// Toggle microphone mute state for active recording
    func toggleMicrophoneMute() {
        guard let session = activeRecordingSession else { return }
        session.isMicrophoneMuted.toggle()
        isMicrophoneMuted = session.isMicrophoneMuted // Keep ViewModel's sync property updated
    }
}
