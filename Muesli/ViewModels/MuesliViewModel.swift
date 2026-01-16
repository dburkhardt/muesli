import Foundation
import SwiftUI
import ScreenCaptureKit
import CoreMedia
import os.lock

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
            UserDefaults.standard.bool(forKey: AppStorageKeys.hasCompletedOnboarding)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: AppStorageKeys.hasCompletedOnboarding)
        }
    }
    
    // MARK: - Model Management (shared instance)
    
    let modelManager: ModelManager
    
    /// LLM Manager for transcript stitching (optional enhancement)
    let llmManager: LLMManager
    
    /// Update checker for app updates
    let updateChecker = UpdateChecker.shared
    
    /// Latest update status from background check
    var latestUpdateStatus: UpdateChecker.UpdateStatus?
    
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
    
    // MARK: - Recording Controller
    // ⚠️ IMPORTANT: All recording logic lives in RecordingController.
    // Do NOT add recording implementation here - delegate to recordingController.
    // See RecordingController.swift for audio capture, transcription coordination, 
    // and file output management.
    
    /// Recording controller - owns all recording lifecycle logic
    private let recordingController: RecordingController
    
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
    // NOTE: Delegates to RecordingController - do not manage session state here
    
    /// The currently recording session (delegates to RecordingController)
    var activeSession: RecordingSession? {
        recordingController.activeSession
    }
    
    /// Alias for activeSession (for clarity in new UI)
    var activeRecordingSession: RecordingSession? {
        recordingController.activeSession
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
    
    // MARK: - Model Error Alert State (delegating to RecordingController)
    
    /// Whether to show the model error alert (delegates to recordingController)
    var showModelErrorAlert: Bool {
        get { recordingController.showModelErrorAlert }
        set { recordingController.showModelErrorAlert = newValue }
    }
    
    /// Session waiting for user response to model error (delegates to recordingController)
    var sessionPendingModelDecision: RecordingSession? {
        get { recordingController.sessionPendingModelDecision }
        set { recordingController.sessionPendingModelDecision = newValue }
    }
    
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
    
    // NOTE: showModelErrorAlert and sessionPendingModelDecision are defined above
    // in the "Model Error Alert State" section, delegating to recordingController
    
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
    
    // MARK: - Microphone Mute (delegates to RecordingController)
    
    /// Toggle microphone mute state for active recording
    func toggleMicrophoneMute() {
        recordingController.toggleMicrophoneMute()
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
    ///   - llmManager: LLM Manager for transcript refinement (injectable, shared instance)
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
        llmManager: LLMManager? = nil,
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
        
        // Use shared LLMManager instance if provided, otherwise create new one
        // This ensures MuesliApp can inject the shared instance
        self.llmManager = llmManager ?? LLMManager(skipHubAccess: skipInitialLoad)
        
        self.preferencesManager = preferencesManager
        self.historyManager = historyManager ?? MeetingHistoryManager(skipInitialLoad: skipInitialLoad)
        
        // Create transcription coordinator (manages model lifecycle and audio buffering)
        self.transcriptionCoordinator = TranscriptionCoordinator(
            transcriptionService: self.transcriptionService,
            modelManager: self.modelManager
        )
        
        // Create refinement coordinator if not provided, using the shared llmManager
        self.refinementCoordinator = refinementCoordinator ?? RefinementCoordinator(
            llmManager: self.llmManager,
            fileOutputService: self.fileOutputService
        )
        
        // Create recording controller (owns all recording lifecycle logic)
        self.recordingController = RecordingController(
            audioCaptureService: self.audioCaptureService,
            fileOutputService: self.fileOutputService,
            transcriptionService: self.transcriptionService,
            transcriptionCoordinator: self.transcriptionCoordinator,
            echoCancellationService: self.echoCancellationService,
            preferencesManager: preferencesManager,
            microphoneManager: self.microphoneManager
        )
        
        // Check initial permission status
        refreshPermissions()
        
        // If microphone permission is already granted (returning user),
        // refresh microphone devices. This is safe because permission is already granted.
        if self.permissionManager.hasMicrophonePermission {
            self.microphoneManager.refreshDevices()
        }
        
        // Set initial transcription mode
        transcriptionCoordinator.setTranscriptionMode(transcriptionMode)
        
        // Wire up RecordingController callbacks to ViewModel state
        self.recordingController.onSessionCompleted = { [weak self] session, outputDirectory in
            guard let self = self else { return }
            
            // Refresh history first to ensure the new meeting is available
            self.refreshMeetingHistory()
            
            // Find and select the newly completed meeting
            if let directory = outputDirectory,
               let newMeeting = self.meetingHistory.first(where: { $0.directory == directory }) {
                self.selectedMeeting = newMeeting
                self.isSplitViewVisible = true
            } else if self.selectedMeeting == nil {
                // Fallback: if no meeting found and nothing selected, hide split view
                self.isSplitViewVisible = false
            }
        }
        
        self.recordingController.onRefreshHistory = { [weak self] in
            self?.refreshMeetingHistory()
        }
        
        self.recordingController.onSelectedMeetingChanged = { [weak self] meeting in
            self?.selectedMeeting = meeting
        }
        
        self.recordingController.onSplitViewVisibilityChanged = { [weak self] visible in
            self?.isSplitViewVisible = visible
        }
        
        // Load available meeting apps
        Task {
            await refreshMeetingApps()
        }
        
        // Note: Meeting history is already loaded by MeetingHistoryManager's init
        // No need to call loadMeetingHistory() here as historyManager handles it
    }
    
    // MARK: - Session Management (delegates to RecordingController)
    
    /// Create a new recording session
    func createSession() -> RecordingSession {
        return recordingController.createSession()
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
        
        // If permission was granted, refresh microphone devices
        // This was deferred during init to avoid triggering the permission prompt
        if hasMicrophonePermission {
            microphoneManager.refreshDevices()
        }
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
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.hasCompletedOnboarding)
    }
    
    // MARK: - Meeting App Detection
    
    func refreshMeetingApps() async {
        availableMeetingApps = await meetingAppDetector.detectMeetingApps()
    }
    
    // MARK: - Recording Actions
    // ⚠️ IMPORTANT: All recording implementation is in RecordingController.
    // These methods delegate to recordingController. Do NOT duplicate logic here.
    
    /// Quick start recording with all system audio (no app selection needed)
    func quickStartRecording() {
        // Ensure live transcription mode before starting
        transcriptionMode = .live
        
        // Clear selection before recording
        selectedMeeting = nil
        selectedMeetingIDs.removeAll()
        
        recordingController.quickStartRecording()
        isSplitViewVisible = true
    }
    
    /// Start recording for a session
    func startRecording(for session: RecordingSession) {
        // Clear selection before recording
        selectedMeeting = nil
        selectedMeetingIDs.removeAll()
        
        recordingController.startRecording(for: session)
    }
    
    /// Stop recording for a session
    func stopRecording(for session: RecordingSession) {
        guard session.id == activeSession?.id else { return }
        
        // Check if title is empty - show prompt sheet (UI handled by ViewModel)
        if session.meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingStopSession = session
            showTitlePromptSheet = true
            return
        }
        
        recordingController.stopRecording(for: session)
    }
    
    /// Called after title prompt is confirmed or skipped
    func confirmStopRecording() {
        guard let session = pendingStopSession else { return }
        pendingStopSession = nil
        recordingController.stopRecording(for: session)
    }
    
    /// Discard the current recording without saving
    func discardRecording() {
        pendingStopSession = nil
        showTitlePromptSheet = false
        recordingController.discardRecording()
    }
    
    // MARK: - Model Error Handling
    
    /// Start recording without transcription (audio only)
    func startRecordingWithoutTranscription() {
        recordingController.startRecordingWithoutTranscription()
    }
    
    /// Cancel recording due to model error
    func cancelRecordingDueToModelError() {
        recordingController.cancelRecordingDueToModelError()
    }
    
    /// Re-transcribe a completed recording with post-processing mode
    func retranscribeWithPostProcessing(for session: RecordingSession) {
        recordingController.retranscribeWithPostProcessing(for: session)
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
    func loadTranscript(for meeting: MeetingHistoryItem) async {
        await historyManager.loadTranscript(for: meeting)
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
            Task {
                await loadTranscript(for: meeting)
            }
        }
        refinementCoordinator.refineTranscript(for: meeting)
    }
    
    /// Cancel ongoing refinement (delegates to refinementCoordinator)
    func cancelRefinement() {
        refinementCoordinator.cancelRefinement()
    }
    
    // MARK: - Transcript Reprocessing
    
    /// Reprocess a meeting's transcript with a different model
    /// - Parameters:
    ///   - meeting: The meeting to reprocess
    ///   - model: The model to use for reprocessing
    func reprocessTranscript(for meeting: MeetingHistoryItem, using model: ModelManager.ModelSize) {
        guard !meeting.isReprocessing else { return }
        
        Task {
            meeting.isReprocessing = true
            meeting.reprocessingProgress = 0.0
            
            do {
                try await transcriptionCoordinator.reprocessTranscript(
                    for: meeting,
                    using: model
                ) { progress in
                    Task { @MainActor in
                        meeting.reprocessingProgress = progress
                    }
                }
                
                // Reload transcript from disk to refresh the UI
                await loadTranscript(for: meeting)
                
            } catch {
                print("[MuesliViewModel] Reprocessing failed: \(error.localizedDescription)")
            }
            
            meeting.isReprocessing = false
            meeting.reprocessingProgress = 0.0
        }
    }
    
    /// Bulk reprocess selected meetings with a specific model
    /// - Parameter model: The model to use for reprocessing
    func bulkReprocessTranscripts(using model: ModelManager.ModelSize) {
        let meetingsToProcess = historyManager.selectedMeetings
        
        Task {
            for meeting in meetingsToProcess {
                await reprocessTranscript(for: meeting, using: model)
            }
        }
    }
    
    /// Helper for synchronous reprocessing wrapper
    private func reprocessTranscript(for meeting: MeetingHistoryItem, using model: ModelManager.ModelSize) async {
        guard !meeting.isReprocessing else { return }
        
        meeting.isReprocessing = true
        meeting.reprocessingProgress = 0.0
        
        do {
            try await transcriptionCoordinator.reprocessTranscript(
                for: meeting,
                using: model
            ) { progress in
                Task { @MainActor in
                    meeting.reprocessingProgress = progress
                }
            }
            
            // Reload transcript from disk
            await loadTranscript(for: meeting)
            
        } catch {
            print("[MuesliViewModel] Reprocessing failed: \(error.localizedDescription)")
        }
        
        meeting.isReprocessing = false
        meeting.reprocessingProgress = 0.0
    }
    
    // MARK: - Resume Recording (delegates to RecordingController)
    
    /// Resume recording for a completed meeting
    func resumeRecording(for meeting: MeetingHistoryItem) {
        recordingController.resumeRecording(for: meeting)
    }
    
    // MARK: - Update Checking
    
    /// Check for updates on app launch (with 24-hour throttling)
    func checkForUpdatesOnLaunch() async {
        // Only check if enough time has passed since last check (24 hours)
        guard updateChecker.shouldCheckForUpdates() else {
            return
        }
        
        latestUpdateStatus = await updateChecker.checkForUpdates()
    }
    
    /// Check for updates immediately (ignores throttling)
    func checkForUpdatesNow() async {
        latestUpdateStatus = await updateChecker.checkForUpdates()
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
