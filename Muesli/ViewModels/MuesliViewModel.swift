import Foundation
import SwiftUI
import ScreenCaptureKit
import CoreMedia

/// Main ViewModel for the Muesli app
/// Owns app-level state (permissions, detected apps) and services
/// Recording sessions are managed separately via RecordingSession objects
@Observable
@MainActor
final class MuesliViewModel {
    
    // MARK: - Injected Managers
    
    /// Preferences manager (injected, source of truth for preferences)
    private let preferencesManager: PreferencesManager
    
    /// Meeting history manager (injected, source of truth for meeting history)
    let historyManager: MeetingHistoryManager
    
    /// Refinement coordinator (injected, source of truth for refinement state)
    let refinementCoordinator: RefinementCoordinator
    
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
    
    /// Whether onboarding has been completed (always reads from UserDefaults for consistency)
    var hasCompletedOnboarding: Bool {
        get {
            UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.onboardingCompletedKey)
        }
    }
    
    private static let onboardingCompletedKey = "hasCompletedOnboarding"
    
    // MARK: - Model Management (shared instance)
    
    let modelManager: ModelManager
    
    /// LLM Manager for transcript stitching (optional enhancement)
    let llmManager: LLMManager
    
    /// Transcript refinement service for post-meeting cleanup
    private(set) var refinementService: TranscriptRefinementService!
    
    /// Convenience accessor for the active model path
    var modelPath: URL? {
        modelManager.modelPath
    }
    
    // MARK: - Services (injectable for testing)
    
    private let audioCaptureService: AudioCaptureService
    private let fileOutputService: FileOutputService
    private let transcriptionService: TranscriptionService
    private let meetingAppDetector: MeetingAppDetector
    private let permissionManager: PermissionManager
    let microphoneManager: MicrophoneManager
    private let meetingHistoryService: MeetingHistoryService
    
    // Echo cancellation service (optional - can be enabled/disabled)
    private let echoCancellationService: EchoCancellationService
    
    // Transcription coordinator (manages model lifecycle and audio buffering)
    private let transcriptionCoordinator: TranscriptionCoordinator
    
    /// Whether echo cancellation is enabled (delegates to PreferencesManager)
    var isEchoCancellationEnabled: Bool {
        get {
            preferencesManager.isEchoCancellationEnabled
        }
        set {
            preferencesManager.isEchoCancellationEnabled = newValue
        }
    }
    
    // MARK: - Transcription State
    
    /// Transcription mode: live (real-time) or post-processing (after recording)
    /// Delegates to PreferencesManager for persistence
    var transcriptionMode: TranscriptionService.TranscriptionMode {
        get {
            preferencesManager.transcriptionMode.serviceMode
        }
        set {
            preferencesManager.transcriptionMode = PreferencesManager.TranscriptionMode(from: newValue)
            transcriptionCoordinator.setTranscriptionMode(newValue)
        }
    }
    
    // MARK: - Active Session Tracking
    
    /// The currently recording session (only one can record at a time)
    private(set) var activeSession: RecordingSession?
    
    /// Alias for activeSession (for clarity in new UI)
    var activeRecordingSession: RecordingSession? {
        activeSession
    }
    
    // MARK: - Meeting History (delegating to MeetingHistoryManager)
    
    /// All discovered meeting recordings (delegates to historyManager)
    var meetingHistory: [MeetingHistoryItem] {
        get { historyManager.meetingHistory }
        set { historyManager.meetingHistory = newValue }
    }
    
    /// Meeting history grouped by date (delegates to historyManager)
    var groupedHistory: [MeetingHistoryGroup] {
        get { historyManager.groupedHistory }
        set { historyManager.groupedHistory = newValue }
    }
    
    /// Currently selected meeting for viewing (delegates to historyManager)
    var selectedMeeting: MeetingHistoryItem? {
        get { historyManager.selectedMeeting }
        set { historyManager.selectedMeeting = newValue }
    }
    
    /// Set of selected meeting IDs (for multi-select) (delegates to historyManager)
    var selectedMeetingIDs: Set<UUID> {
        get { historyManager.selectedMeetingIDs }
        set { historyManager.selectedMeetingIDs = newValue }
    }
    
    /// Meeting to show in completed meeting window (delegates to historyManager)
    var completedMeetingWindowItem: MeetingHistoryItem? {
        get { historyManager.completedMeetingWindowItem }
        set { historyManager.completedMeetingWindowItem = newValue }
    }
    
    /// Whether to show delete confirmation dialog (delegates to historyManager)
    var showDeleteConfirmation: Bool {
        get { historyManager.showDeleteConfirmation }
        set { historyManager.showDeleteConfirmation = newValue }
    }
    
    /// Meetings pending deletion (after confirmation) (delegates to historyManager)
    var meetingsPendingDeletion: [MeetingHistoryItem] {
        get { historyManager.meetingsPendingDeletion }
        set { historyManager.meetingsPendingDeletion = newValue }
    }
    
    /// Error from most recent deletion attempt (delegates to historyManager)
    var deletionError: String? {
        get { historyManager.deletionError }
        set { historyManager.deletionError = newValue }
    }
    
    /// Whether the split view (sidebar + detail) should be visible
    var isSplitViewVisible: Bool = false
    
    /// Whether to show the start recording sheet
    var showStartRecordingSheet: Bool = false
    
    /// Whether to show the meeting title prompt sheet
    var showTitlePromptSheet: Bool = false
    
    /// Session pending stop (waiting for title input)
    var pendingStopSession: RecordingSession?
    
    // MARK: - Refinement State (delegating to RefinementCoordinator)
    
    /// Whether to show the refinement progress sheet (delegates to refinementCoordinator)
    var showRefineSheet: Bool {
        get { refinementCoordinator.showRefineSheet }
        set { refinementCoordinator.showRefineSheet = newValue }
    }
    
    /// Whether to show the post-meeting refinement prompt (delegates to refinementCoordinator)
    var showRefinementPrompt: Bool {
        get { refinementCoordinator.showRefinementPrompt }
        set { refinementCoordinator.showRefinementPrompt = newValue }
    }
    
    /// Get whether to show original transcript for a meeting (delegates to refinementCoordinator)
    func showOriginalTranscript(for meeting: MeetingHistoryItem) -> Bool {
        refinementCoordinator.isShowingOriginal(for: meeting)
    }
    
    /// Toggle showing original transcript for a meeting (delegates to refinementCoordinator)
    func toggleOriginalTranscript(for meeting: MeetingHistoryItem) {
        let newValue = !refinementCoordinator.isShowingOriginal(for: meeting)
        refinementCoordinator.setShowingOriginal(newValue, for: meeting, historyService: meetingHistoryService)
    }
    
    /// Meeting being refined (delegates to refinementCoordinator)
    var meetingBeingRefined: MeetingHistoryItem? {
        get { refinementCoordinator.meetingBeingRefined }
        set { refinementCoordinator.meetingBeingRefined = newValue }
    }
    
    // MARK: - Model Error Alert
    
    /// Whether to show the model error alert
    var showModelErrorAlert: Bool = false
    
    /// Session waiting for user response to model error
    var sessionPendingModelDecision: RecordingSession?
    
    // MARK: - Preferences (delegating to PreferencesManager)
    
    /// Output directory for recordings (delegates to PreferencesManager)
    var outputDirectory: URL {
        get {
            preferencesManager.outputDirectory
        }
        set {
            preferencesManager.outputDirectory = newValue
            fileOutputService.setOutputDirectory(newValue)
        }
    }
    
    /// Default output directory: ~/Library/Application Support/Muesli/Recordings
    static var defaultOutputDirectory: URL {
        PreferencesManager.defaultOutputDirectory
    }
    
    /// Set the output directory
    func setOutputDirectory(_ url: URL) {
        outputDirectory = url
    }
    
    /// Reset output directory to default
    func resetOutputDirectory() {
        preferencesManager.resetOutputDirectory()
        fileOutputService.setOutputDirectory(Self.defaultOutputDirectory)
    }
    
    /// Whether to launch at login (delegates to PreferencesManager)
    var launchAtLogin: Bool {
        get {
            preferencesManager.launchAtLogin
        }
        set {
            preferencesManager.launchAtLogin = newValue
        }
    }
    
    /// Set launch at login
    func setLaunchAtLogin(_ enabled: Bool) {
        preferencesManager.setLaunchAtLogin(enabled)
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
    
    /// Microphone mute state (for synchronous access from audio callback)
    /// Uses nonisolated(unsafe) for thread-safe access from audio callback
    nonisolated(unsafe) private var isMicrophoneMuted: Bool = false
    
    /// Toggle microphone mute state for active recording
    func toggleMicrophoneMute() {
        guard let session = activeRecordingSession else { return }
        session.isMicrophoneMuted.toggle()
        isMicrophoneMuted = session.isMicrophoneMuted
    }
    
    /// Helper to reset mute state when session is cleared
    private func resetMuteState() {
        isMicrophoneMuted = false
    }
    
    // MARK: - Initialization
    
    /// Initialize the ViewModel with injected managers and services
    /// - Parameters:
    ///   - preferencesManager: Manager for user preferences
    ///   - historyManager: Manager for meeting history (if nil, creates one with skipInitialLoad)
    ///   - refinementCoordinator: Coordinator for transcript refinement
    ///   - audioCaptureService: Service for capturing audio (injectable for testing)
    ///   - fileOutputService: Service for file output (injectable for testing)
    ///   - transcriptionService: Service for transcription (injectable for testing)
    ///   - meetingAppDetector: Service for detecting meeting apps (injectable for testing)
    ///   - permissionManager: Manager for permissions (injectable for testing)
    ///   - microphoneManager: Manager for microphone devices (injectable for testing)
    ///   - meetingHistoryService: Service for meeting history (injectable for testing)
    ///   - echoCancellationService: Service for echo cancellation (injectable for testing)
    ///   - skipInitialLoad: If true, skips loading meeting history from disk (for testing)
    init(
        preferencesManager: PreferencesManager = PreferencesManager(),
        historyManager: MeetingHistoryManager? = nil,
        refinementCoordinator: RefinementCoordinator? = nil,
        audioCaptureService: AudioCaptureService? = nil,
        fileOutputService: FileOutputService? = nil,
        transcriptionService: TranscriptionService? = nil,
        meetingAppDetector: MeetingAppDetector? = nil,
        permissionManager: PermissionManager? = nil,
        microphoneManager: MicrophoneManager? = nil,
        meetingHistoryService: MeetingHistoryService? = nil,
        echoCancellationService: EchoCancellationService? = nil,
        skipInitialLoad: Bool = false
    ) {
        // Initialize services (use provided or create defaults)
        self.audioCaptureService = audioCaptureService ?? AudioCaptureService()
        self.fileOutputService = fileOutputService ?? FileOutputService()
        self.transcriptionService = transcriptionService ?? TranscriptionService()
        self.meetingAppDetector = meetingAppDetector ?? MeetingAppDetector()
        self.permissionManager = permissionManager ?? PermissionManager()
        self.microphoneManager = microphoneManager ?? MicrophoneManager()
        self.meetingHistoryService = meetingHistoryService ?? MeetingHistoryService()
        self.echoCancellationService = echoCancellationService ?? EchoCancellationService(
            filterLength: 256,
            learningRate: 0.3,
            sampleRate: 48000,
            maxDelayMs: 100
        )
        
        // Initialize managers (skip scanning during tests to avoid file system/Documents prompts)
        self.modelManager = ModelManager(skipScan: skipInitialLoad)
        self.llmManager = LLMManager(skipHubAccess: skipInitialLoad)
        
        self.preferencesManager = preferencesManager
        self.historyManager = historyManager ?? MeetingHistoryManager(skipInitialLoad: skipInitialLoad)
        
        // Create transcription coordinator (manages model lifecycle and audio buffering)
        self.transcriptionCoordinator = TranscriptionCoordinator(
            transcriptionService: self.transcriptionService,
            modelManager: self.modelManager
        )
        
        // Create refinement coordinator if not provided
        self.refinementCoordinator = refinementCoordinator ?? RefinementCoordinator(
            llmManager: llmManager,
            fileOutputService: self.fileOutputService
        )
        
        // Initialize refinement service
        refinementService = TranscriptRefinementService(llmManager: llmManager)
        
        // Check initial permission status
        refreshPermissions()
        
        // Set up audio buffer handler - fork to both file output and transcription
        // Use self. to capture the non-optional instance properties (not the optional init parameters)
        let fileService = self.fileOutputService
        let transcriptService = self.transcriptionService
        let aecService = self.echoCancellationService
        let prefs = self.preferencesManager
        let audioCaptureServiceRef = self.audioCaptureService
        Task {
            await audioCaptureServiceRef.setBufferHandler { [weak self] buffer, type in
                guard let self = self else { return }
                
                // Check if microphone is muted (synchronous check)
                let isMicMuted = self.isMicrophoneMuted
                // Read AEC state from PreferencesManager's nonisolated accessor (single source of truth)
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
            
            // Set up stream interruption handler (e.g., captured app quits)
            await audioCaptureServiceRef.setInterruptedHandler { [weak self] error in
                Task { @MainActor in
                    self?.handleCaptureInterrupted(error: error)
                }
            }
            
            // Set up audio level handler for microphone indicator
            await audioCaptureServiceRef.setLevelHandler { [weak self] level, type in
                Task { @MainActor in
                    self?.updateAudioLevel(level, type: type)
                }
            }
        }
        
        // Set initial transcription mode
        transcriptionCoordinator.setTranscriptionMode(transcriptionMode)
        
        // Load available meeting apps
        Task {
            await refreshMeetingApps()
        }
        
        // Note: Meeting history is already loaded by MeetingHistoryManager's init
        // No need to call loadMeetingHistory() here as historyManager handles it
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
    
    // MARK: - Onboarding
    
    func completeOnboarding() {
        // Model path is now managed by ModelManager, we just mark onboarding as done
        hasCompletedOnboarding = true
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
        isMicrophoneMuted = session.isMicrophoneMuted
        
        // Mark as initializing (loading model)
        session.isInitializing = true
        
        // Clear selectedMeeting so UI shows the new recording, not an old meeting
        selectedMeeting = nil
        selectedMeetingIDs.removeAll()
        
        Task {
            await startRecordingAsync(for: session)
        }
    }
    
    private func startRecordingAsync(for session: RecordingSession) async {
        do {
            // Prepare transcription model using coordinator (handles validation, fallback, initialization)
            let modelState = await transcriptionCoordinator.prepareModel()
            
            switch modelState {
            case .notAvailable:
                // No valid model available
                session.isInitializing = false
                session.state = .idle
                activeSession = nil
                resetMuteState()
                sessionPendingModelDecision = session
                showModelErrorAlert = true
                return
                
            case .loading:
                // Model is loading - coordinator will buffer audio until ready
                // Continue with recording setup
                break
                
            case .ready:
                // Model is ready - transcription can start immediately
                break
                
            case .failed(let error):
                // Model loading failed - show error
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
            
            // Start audio capture - either filtered to a specific app or all system audio
            if let app = session.selectedApp {
                try await audioCaptureService.startCapture(forBundleIdentifier: app.bundleIdentifier)
            } else {
                // Capture all system audio (no app filter)
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
            
            // Start transcription through coordinator (handles buffering if model still loading)
            transcriptionCoordinator.startTranscription(recordingStartTime: session.recordingStartTime ?? Date())
            
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
            session.isInitializing = false
            session.state = .idle
            activeSession = nil
        resetMuteState()  // Clear since setup failed
            
            if fileOutputService.isWriting {
                _ = try? await fileOutputService.stopWriting()
            }
        } catch {
            // Handle any remaining errors (model errors are handled by coordinator above)
            let errorMsg = error.localizedDescription
            
            if errorMsg.contains("TCC") || errorMsg.contains("declined") || errorMsg.contains("permission") {
                session.showErrorMessage("Please grant Screen Recording permission and try again.")
            } else {
                session.showErrorMessage("Failed to start recording: \(errorMsg)")
            }
            session.isInitializing = false
            session.state = .idle
            activeSession = nil
            resetMuteState()
            
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
    
    // MARK: - Model Error Handling
    
    /// Start recording without transcription (audio only)
    func startRecordingWithoutTranscription() {
        guard let session = sessionPendingModelDecision else { return }
        sessionPendingModelDecision = nil
        showModelErrorAlert = false
        
        // For now, just show an error - full recording-only mode would need more work
        session.showErrorMessage("Recording without transcription is not yet supported. Please download a working model in Preferences.")
    }
    
    /// Cancel recording due to model error
    func cancelRecordingDueToModelError() {
        sessionPendingModelDecision = nil
        showModelErrorAlert = false
    }
    
    private func discardRecordingAsync(for session: RecordingSession) async {
        session.state = .stopping
        session.stopDisplayTimer()
        
        do {
            // Stop audio capture
            try await audioCaptureService.stopCapture()
            
            // Reset echo cancellation filter
            echoCancellationService.reset()
            
            // Stop transcription without processing remaining audio
            await transcriptionCoordinator.stopTranscription()
            
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
        resetMuteState()
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
            
            // Reset echo cancellation filter
            echoCancellationService.reset()
            
            // Stop transcription and process remaining audio (for live mode)
            await transcriptionCoordinator.stopTranscription()
            
            // Finalize file output
            guard let directory = try? await fileOutputService.stopWriting() else {
                session.state = .completed
                activeSession = nil
        resetMuteState()
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
            
            // Finalize transcript processing
            session.finalizeTranscript()
            
            // Determine if this is a resumed recording or new recording
            let isResumed = session.resumeCount > 0
            let meeting: MeetingHistoryItem
            
            if isResumed, let parentMeeting = session.parentMeeting {
                // This is a resumed recording - update existing meeting
                meeting = parentMeeting
                
                // Create transcript segment for this recording segment
                let segment = TranscriptSegment(
                    segmentNumber: session.segmentNumber,
                    originalBlocks: session.transcriptBlocks,
                    refinedBlocks: nil,
                    isRefined: false,
                    startTime: session.recordingStartTime ?? Date()
                )
                
                // Add segment to meeting
                meeting.transcriptSegments.append(segment)
                meeting.segmentCount = meeting.transcriptSegments.count
                
                // Refine this segment if LLM is available
                if canRefineTranscripts {
                    Task {
                        await refineSegment(segment, in: meeting)
                    }
                }
                
                // Update transcript display (combine all segments)
                updateMeetingTranscriptDisplay(meeting)
                
            } else {
                // This is a new recording - save transcript first, then create segment
                // Save transcript blocks to file (legacy format for compatibility)
                try? fileOutputService.saveTranscriptBlocks(
                    session.transcriptBlocks,
                    title: session.meetingTitle.isEmpty ? "Meeting" : session.meetingTitle,
                    date: session.recordingStartTime ?? Date(),
                    to: directory
                )
                
                // Refresh meeting history to include the new recording
                refreshMeetingHistory()
                
                // Find the newly created meeting
                if let newMeeting = meetingHistory.first(where: { $0.directory == directory }) {
                    // Create transcript segment for first segment
                    let segment = TranscriptSegment(
                        segmentNumber: 1,
                        originalBlocks: session.transcriptBlocks,
                        refinedBlocks: nil,
                        isRefined: false,
                        startTime: session.recordingStartTime ?? Date()
                    )
                    
                    newMeeting.transcriptSegments = [segment]
                    newMeeting.segmentCount = 1
                    newMeeting.canResume = true  // Mark as resumable
                    meeting = newMeeting
                    
                    // Select this meeting immediately (before any more refreshes)
                    selectedMeeting = newMeeting
                    
                    // Refine this segment if LLM is available
                    if canRefineTranscripts {
                        Task {
                            await refineSegment(segment, in: newMeeting)
                        }
                    }
                    
                    // Save updated transcript with segments
                    try? saveTranscriptWithSegments(newMeeting, to: directory)
                } else {
                    // Fallback: meeting not found (shouldn't happen)
                    session.state = .completed
                    activeSession = nil
                    resetMuteState()
                    return
                }
            }
            
            // Save transcript to file (combined format with segment markers)
            try? saveTranscriptWithSegments(meeting, to: directory)
            
        } catch {
            session.showErrorMessage("Error stopping recording: \(error.localizedDescription)")
        }
        
        // Mark session as completed and resumable
        session.state = .completed
        session.canResume = true

        // Only refresh and select if we haven't already selected the meeting
        // (new recordings set selectedMeeting earlier to preserve segment data)
        if selectedMeeting == nil {
            refreshMeetingHistory()
            if let directory = session.outputDirectory {
                selectedMeeting = meetingHistory.first { $0.directory == directory }
            }
        }

        // Clear activeSession
        activeSession = nil
        resetMuteState()
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
            
            // Reset echo cancellation filter
            echoCancellationService.reset()
            
            // Stop transcription and process remaining audio (for live mode)
            await transcriptionCoordinator.stopTranscription()
            
            // Finalize file output
            guard let directory = try? await fileOutputService.stopWriting() else {
                session.state = .completed
                session.showErrorMessage("Recording was interrupted: \(session.interruptionReason ?? "Unknown reason")")
                activeSession = nil
        resetMuteState()
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
        resetMuteState()
        } else {
            activeSession = nil
        resetMuteState()
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
        
        // Set retranscribing state
        session.isRetranscribing = true
        
        // Prepare transcription model using coordinator
        let modelState = await transcriptionCoordinator.prepareModel()
        
        switch modelState {
        case .notAvailable:
            session.isRetranscribing = false
            session.showErrorMessage("No transcription model configured.")
            return
            
        case .loading:
            // Wait for model to finish loading
            break
            
        case .ready:
            // Model is ready for transcription
            break
            
        case .failed(let error):
            session.isRetranscribing = false
            session.showErrorMessage("Failed to initialize transcription: \(error.localizedDescription)")
            return
        }
        
        // Set transcription mode to post-processing temporarily
        let previousMode = transcriptionCoordinator.transcriptionMode
        transcriptionCoordinator.setTranscriptionMode(TranscriptionService.TranscriptionMode.postProcessing)
        
        // Set up transcript handler to process segments through the block pipeline
        transcriptionCoordinator.setTranscriptHandler { [weak session] (segment: TranscriptionService.TranscriptSegment) in
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
        transcriptionCoordinator.setTranscriptionMode(previousMode)
        
        // Clear retranscribing state
        session.isRetranscribing = false
    }
    
    // MARK: - Meeting History Management (delegating to MeetingHistoryManager)
    
    /// Load meeting history from disk (delegates to historyManager)
    func loadMeetingHistory() {
        historyManager.loadMeetingHistory()
    }
    
    /// Refresh meeting history (delegates to historyManager)
    func refreshMeetingHistory() {
        historyManager.refreshMeetingHistory()
    }
    
    /// Group meetings by date (delegates to historyManager)
    func groupMeetingsByDate(_ meetings: [MeetingHistoryItem]) -> [MeetingHistoryGroup] {
        historyManager.groupMeetingsByDate(meetings)
    }
    
    /// Load transcript for a meeting (delegates to historyManager)
    func loadTranscript(for meeting: MeetingHistoryItem) {
        historyManager.loadTranscript(for: meeting)
    }
    
    // MARK: - Meeting Selection (delegating to MeetingHistoryManager)
    
    /// Toggle selection of a meeting (delegates to historyManager)
    func toggleMeetingSelection(_ meeting: MeetingHistoryItem, extendSelection: Bool = false) {
        historyManager.toggleMeetingSelection(meeting, extendSelection: extendSelection)
    }
    
    /// Select all meetings in a range (delegates to historyManager)
    func selectMeetingsInRange(to meeting: MeetingHistoryItem) {
        historyManager.selectMeetingsInRange(to: meeting)
    }
    
    /// Clear all selections (delegates to historyManager)
    func clearSelection() {
        historyManager.clearSelection()
    }
    
    /// Get selected meetings (delegates to historyManager)
    var selectedMeetings: [MeetingHistoryItem] {
        historyManager.selectedMeetings
    }
    
    // MARK: - Meeting Deletion (delegating to MeetingHistoryManager)
    
    /// Request deletion of selected meetings (delegates to historyManager)
    func requestDeleteSelectedMeetings() {
        historyManager.requestDeleteSelectedMeetings()
    }
    
    /// Request deletion of a specific meeting (delegates to historyManager)
    func requestDeleteMeeting(_ meeting: MeetingHistoryItem) {
        historyManager.requestDeleteMeeting(meeting)
    }
    
    /// Confirm and execute deletion (delegates to historyManager)
    func confirmDeleteMeetings() {
        historyManager.confirmDeleteMeetings()
    }
    
    /// Cancel deletion (delegates to historyManager)
    func cancelDeleteMeetings() {
        historyManager.cancelDeleteMeetings()
    }
    
    /// Clear the deletion error state (delegates to historyManager)
    func clearDeletionError() {
        historyManager.clearDeletionError()
    }
    
    // MARK: - Transcript Refinement (delegating to RefinementCoordinator)
    
    /// Check if refinement is available (delegates to refinementCoordinator)
    var canRefineTranscripts: Bool {
        refinementCoordinator.canRefineTranscripts
    }
    
    /// Start refining a meeting's transcript (delegates to refinementCoordinator)
    func refineTranscript(for meeting: MeetingHistoryItem) {
        // Ensure transcript is loaded first
        if meeting.transcriptBlocks == nil && meeting.transcript == nil {
            loadTranscript(for: meeting)
        }
        refinementCoordinator.refineTranscript(for: meeting)
    }
    
    /// Cancel ongoing refinement (delegates to refinementCoordinator)
    func cancelRefinement() {
        refinementCoordinator.cancelRefinement()
    }
    
    // MARK: - Resume Recording
    
    /// Resume recording for a completed meeting
    /// - Parameter meeting: The meeting to resume recording for
    func resumeRecording(for meeting: MeetingHistoryItem) {
        guard meeting.canResume else { return }
        guard activeSession == nil else {
            return  // Already recording
        }
        
        Task {
            await resumeRecordingAsync(for: meeting)
        }
    }
    
    /// Async implementation of resume recording
    private func resumeRecordingAsync(for meeting: MeetingHistoryItem) async {
        do {
            // Prepare transcription model using coordinator
            let modelState = await transcriptionCoordinator.prepareModel()
            
            switch modelState {
            case .notAvailable, .failed:
                // No valid model available - fail silently for resume
                return
                
            case .loading:
                // Model is loading - coordinator will buffer audio until ready
                break
                
            case .ready:
                // Model is ready for transcription
                break
            }
            
            // Create new session linked to existing meeting
            let session = createSession()
            session.parentMeeting = meeting
            session.resumeCount = meeting.segmentCount
            session.segmentNumber = meeting.segmentCount + 1
            session.meetingTitle = meeting.title
            session.selectedApp = nil  // Use same audio source settings (could be enhanced to remember)
            
            // Set activeSession immediately
            activeSession = session
            isMicrophoneMuted = session.isMicrophoneMuted
            
            // Set up transcript handler through coordinator
            transcriptionCoordinator.setTranscriptHandler { [weak session] (segment: TranscriptionService.TranscriptSegment) in
                Task { @MainActor in
                    guard let session = session else { return }
                    session.appendTranscriptSegment(segment)
                }
            }
            
            // Resume file output with incremented segment number
            session.outputDirectory = try fileOutputService.resumeWriting(
                to: meeting.directory,
                segmentNumber: session.segmentNumber
            )
            
            // Configure microphone preference before starting capture
            if let selectedMicID = microphoneManager.selectedDeviceID {
                microphoneManager.setSelectedDeviceID(selectedMicID)
            }
            
            // Start audio capture (use same settings as original - all system audio for now)
            try await audioCaptureService.startCapture()
            
            // Update session state on success
            session.isInitializing = false
            session.state = .recording
            session.recordingStartTime = Date()
            session.transcriptText = ""
            session.transcriptBlocks = []
            session.resetTranscript()
            session.startDisplayTimer()
            
            // Start transcription through coordinator
            transcriptionCoordinator.startTranscription(recordingStartTime: session.recordingStartTime ?? Date())
            
            // Transition to split view if not already visible
            isSplitViewVisible = true
            
        } catch let error as AudioCaptureService.CaptureError {
            if let session = activeSession {
                switch error {
                case .noContentToCapture:
                    session.showErrorMessage("No audio content available to capture.")
                case .permissionDenied, .streamStartFailed:
                    session.showErrorMessage("Please grant Screen Recording permission and try again.")
                default:
                    session.showErrorMessage("Failed to resume recording: \(error.localizedDescription)")
                }
                session.state = .idle
                activeSession = nil
                resetMuteState()
                
                if fileOutputService.isWriting {
                    _ = try? await fileOutputService.stopWriting()
                }
            }
        } catch {
            if let session = activeSession {
                let errorMsg = error.localizedDescription
                if errorMsg.contains("TCC") || errorMsg.contains("declined") || errorMsg.contains("permission") {
                    session.showErrorMessage("Please grant Screen Recording permission and try again.")
                } else {
                    session.showErrorMessage("Failed to resume recording: \(errorMsg)")
                }
                session.state = .idle
                activeSession = nil
                resetMuteState()
                
                if fileOutputService.isWriting {
                    _ = try? await fileOutputService.stopWriting()
                }
            }
        }
    }
    
    // MARK: - Segment Refinement Helpers
    
    /// Refine a single transcript segment (delegates to refinementCoordinator, then saves)
    private func refineSegment(_ segment: TranscriptSegment, in meeting: MeetingHistoryItem) async {
        await refinementCoordinator.refineSegment(segment, in: meeting)
        
        // Save updated transcript to disk after refinement
            try? saveTranscriptWithSegments(meeting, to: meeting.directory)
    }
    
    /// Update meeting's transcript display from segments (delegates to refinementCoordinator)
    func updateMeetingTranscriptDisplay(_ meeting: MeetingHistoryItem) {
        refinementCoordinator.updateMeetingTranscriptDisplay(meeting)
    }
    
    /// Save transcript with segment markers to disk
    private func saveTranscriptWithSegments(_ meeting: MeetingHistoryItem, to directory: URL) throws {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        
        var markdown = """
        # \(meeting.title.isEmpty ? "Meeting" : meeting.title)
        \(dateFormatter.string(from: meeting.date))
        
        ## Transcript
        
        """
        
        if meeting.transcriptSegments.isEmpty {
            markdown += "_No transcript recorded_"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            
            for segment in meeting.transcriptSegments.sorted(by: { $0.segmentNumber < $1.segmentNumber }) {
                // Add segment marker (except for first segment)
                if segment.segmentNumber > 1 {
                    let resumeTime = formatter.string(from: segment.startTime)
                    markdown += "\n\n---\n\n**Recording resumed at \(resumeTime)**\n\n"
                }
                
                // Use refined blocks if available and showing refined, otherwise use original
                let blocksToUse = (meeting.isShowingRefined && segment.isRefined) ?
                    (segment.refinedBlocks ?? segment.originalBlocks) :
                    segment.originalBlocks
                
                for block in blocksToUse {
                    let speakerLabel = block.speaker == .me ? "**Me**" : "**Them**"
                    let timestamp = formatTimestamp(block.startTimestamp)
                    
                    markdown += """
                    
                    \(speakerLabel) _[\(timestamp)]_
                    
                    \(block.text)
                    
                    """
                }
            }
        }
        
        let transcriptURL = directory.appendingPathComponent("transcript.md")
        try markdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
    }
    
    /// Format a timestamp for display (e.g., "2:34" or "1:02:15")
    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
    
}
