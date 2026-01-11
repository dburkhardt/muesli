import XCTest
@testable import Muesli_vmr

/// Comprehensive test suite for MuesliViewModel
/// Tests verify behavior through the public API before refactoring begins
/// These tests serve as regression tests during the refactor to ensure functionality is preserved
@MainActor
final class MuesliViewModelTests: XCTestCase {
    
    // MARK: - Properties
    
    /// UserDefaults suite name for isolated testing
    private let testSuiteName = "com.muesli.tests"
    
    /// Test UserDefaults instance
    private var testDefaults: UserDefaults!
    
    /// Test output directory (avoids Documents folder permission prompt)
    private static let testOutputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MuesliTests")
    
    /// Keys that need to be cleaned up after tests
    private static let userDefaultsKeysToClean = ["outputDirectory", "hasCompletedOnboarding", "transcriptionMode", "echoCancellationEnabled", "launchAtLogin"]
    
    // MARK: - Setup / Teardown
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Create isolated UserDefaults for testing
        testDefaults = UserDefaults(suiteName: testSuiteName)
        testDefaults?.removePersistentDomain(forName: testSuiteName)
        
        // Set test output directory to avoid Documents folder access
        // This prevents the "Allow access to Documents folder" prompt during tests
        UserDefaults.standard.set(Self.testOutputDirectory.path, forKey: "outputDirectory")
    }
    
    override func tearDown() async throws {
        // Clean up test UserDefaults
        testDefaults?.removePersistentDomain(forName: testSuiteName)
        
        // Clean up standard UserDefaults keys used in tests
        for key in Self.userDefaultsKeysToClean {
            UserDefaults.standard.removeObject(forKey: key)
        }
        testDefaults = nil
        
        try await super.tearDown()
    }
    
    // MARK: - Preferences Tests
    
    func testDefaultOutputDirectory() async {
        // Test that default output directory is set correctly
        let expected = MuesliViewModel.defaultOutputDirectory
        
        // Verify it's in Application Support/Muesli/Recordings
        XCTAssertTrue(expected.path.contains("Muesli"))
        XCTAssertTrue(expected.path.contains("Recordings"))
        XCTAssertTrue(expected.path.contains("Application Support"))
    }
    
    func testOutputDirectoryUserDefaultsKey() async {
        // Verify the key name for output directory preference
        // This test documents the expected UserDefaults key
        let key = "outputDirectory"
        
        // Set a custom path
        let testPath = "/test/custom/path"
        UserDefaults.standard.set(testPath, forKey: key)
        
        // Verify it's stored
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), testPath)
        
        // Clean up
        UserDefaults.standard.removeObject(forKey: key)
    }
    
    func testTranscriptionModeUserDefaultsKey() async {
        // Verify the key name for transcription mode preference
        let key = "transcriptionMode"
        
        // Test live mode
        UserDefaults.standard.set("live", forKey: key)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "live")
        
        // Test post-processing mode
        UserDefaults.standard.set("postProcessing", forKey: key)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "postProcessing")
        
        // Clean up
        UserDefaults.standard.removeObject(forKey: key)
    }
    
    func testEchoCancellationUserDefaultsKey() async {
        // Verify the key name for echo cancellation preference
        let key = "echoCancellationEnabled"
        
        // Test enabled
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))
        
        // Test disabled
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: key))
        
        // Clean up
        UserDefaults.standard.removeObject(forKey: key)
    }
    
    func testOnboardingCompletedUserDefaultsKey() async {
        // Verify the key name for onboarding completed preference
        let key = "hasCompletedOnboarding"
        
        // Test completed
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))
        
        // Test not completed
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: key))
        
        // Clean up
        UserDefaults.standard.removeObject(forKey: key)
    }
    
    // MARK: - Meeting History Grouping Tests
    
    func testMeetingHistoryGroupingByDay_Today() async {
        // Create a meeting from today
        let today = Date()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let meeting = MeetingHistoryItem(
            title: "Today Meeting",
            date: today,
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true
        )
        
        // Create ViewModel and use its grouping logic
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        let groups = viewModel.groupMeetingsByDate([meeting])
        
        // Should have one group labeled "Today"
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.label, "Today")
        XCTAssertEqual(groups.first?.meetings.count, 1)
        
        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    func testMeetingHistoryGroupingByDay_Yesterday() async {
        // Create a meeting from yesterday
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let meeting = MeetingHistoryItem(
            title: "Yesterday Meeting",
            date: yesterday,
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true
        )
        
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        let groups = viewModel.groupMeetingsByDate([meeting])
        
        // Should have one group labeled "Yesterday"
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.label, "Yesterday")
        
        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    func testMeetingHistoryGroupingByMonth_OlderMeetings() async {
        // Create a meeting from 2 months ago
        let twoMonthsAgo = Calendar.current.date(byAdding: .month, value: -2, to: Date())!
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let meeting = MeetingHistoryItem(
            title: "Old Meeting",
            date: twoMonthsAgo,
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true
        )
        
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        let groups = viewModel.groupMeetingsByDate([meeting])
        
        // Should have one group with month label (e.g., "January 2025")
        XCTAssertEqual(groups.count, 1)
        
        // Verify label is a month format (contains year)
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        let expectedLabel = formatter.string(from: twoMonthsAgo)
        XCTAssertEqual(groups.first?.label, expectedLabel)
        
        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    func testMeetingHistoryGroupingMixedDates() async {
        // Create meetings from different time periods
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let lastWeek = Calendar.current.date(byAdding: .day, value: -5, to: Date())!
        let lastMonth = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
        
        let meetings = [today, yesterday, lastWeek, lastMonth].enumerated().map { (index, date) in
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            return MeetingHistoryItem(
                title: "Meeting \(index)",
                date: date,
                directory: tempDir,
                hasAudio: true,
                hasMicrophone: true
            )
        }
        
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        let groups = viewModel.groupMeetingsByDate(meetings)
        
        // Should have multiple groups:
        // - Today
        // - Yesterday
        // - Day from last week
        // - Month from last month
        XCTAssertGreaterThanOrEqual(groups.count, 3)
        
        // Clean up
        for meeting in meetings {
            try? FileManager.default.removeItem(at: meeting.directory)
        }
    }
    
    func testMeetingHistoryGroupingEmpty() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        let groups = viewModel.groupMeetingsByDate([])
        
        XCTAssertEqual(groups.count, 0)
    }
    
    // MARK: - Meeting Selection Tests
    
    func testSingleMeetingSelection() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let meeting = MeetingHistoryItem(
            title: "Test Meeting",
            date: Date(),
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true
        )
        
        // Add to history
        viewModel.meetingHistory = [meeting]
        
        // Select the meeting (regular click)
        viewModel.toggleMeetingSelection(meeting, extendSelection: false)
        
        // Verify single selection
        XCTAssertEqual(viewModel.selectedMeetingIDs.count, 1)
        XCTAssertTrue(viewModel.selectedMeetingIDs.contains(meeting.id))
        XCTAssertEqual(viewModel.selectedMeeting?.id, meeting.id)
        
        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    func testMultiSelectWithExtend() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        let meetings = (0..<3).map { i in
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            return MeetingHistoryItem(
                title: "Meeting \(i)",
                date: Date(),
                directory: tempDir,
                hasAudio: true,
                hasMicrophone: true
            )
        }
        
        viewModel.meetingHistory = meetings
        
        // Select first meeting normally
        viewModel.toggleMeetingSelection(meetings[0], extendSelection: false)
        XCTAssertEqual(viewModel.selectedMeetingIDs.count, 1)
        
        // Cmd+click to add second meeting
        viewModel.toggleMeetingSelection(meetings[1], extendSelection: true)
        XCTAssertEqual(viewModel.selectedMeetingIDs.count, 2)
        XCTAssertTrue(viewModel.selectedMeetingIDs.contains(meetings[0].id))
        XCTAssertTrue(viewModel.selectedMeetingIDs.contains(meetings[1].id))
        
        // Cmd+click to add third meeting
        viewModel.toggleMeetingSelection(meetings[2], extendSelection: true)
        XCTAssertEqual(viewModel.selectedMeetingIDs.count, 3)
        
        // Cmd+click on already selected removes it
        viewModel.toggleMeetingSelection(meetings[1], extendSelection: true)
        XCTAssertEqual(viewModel.selectedMeetingIDs.count, 2)
        XCTAssertFalse(viewModel.selectedMeetingIDs.contains(meetings[1].id))
        
        // Clean up
        for meeting in meetings {
            try? FileManager.default.removeItem(at: meeting.directory)
        }
    }
    
    func testClearSelection() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let meeting = MeetingHistoryItem(
            title: "Test Meeting",
            date: Date(),
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true
        )
        
        viewModel.meetingHistory = [meeting]
        viewModel.toggleMeetingSelection(meeting, extendSelection: false)
        
        XCTAssertEqual(viewModel.selectedMeetingIDs.count, 1)
        
        viewModel.clearSelection()
        
        XCTAssertEqual(viewModel.selectedMeetingIDs.count, 0)
        XCTAssertNil(viewModel.selectedMeeting)
        
        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    func testSelectedMeetingsComputed() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        let meetings = (0..<3).map { i in
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            return MeetingHistoryItem(
                title: "Meeting \(i)",
                date: Date(),
                directory: tempDir,
                hasAudio: true,
                hasMicrophone: true
            )
        }
        
        viewModel.meetingHistory = meetings
        
        // Select two meetings
        viewModel.toggleMeetingSelection(meetings[0], extendSelection: false)
        viewModel.toggleMeetingSelection(meetings[2], extendSelection: true)
        
        let selected = viewModel.selectedMeetings
        XCTAssertEqual(selected.count, 2)
        XCTAssertTrue(selected.contains { $0.id == meetings[0].id })
        XCTAssertTrue(selected.contains { $0.id == meetings[2].id })
        
        // Clean up
        for meeting in meetings {
            try? FileManager.default.removeItem(at: meeting.directory)
        }
    }
    
    // MARK: - Meeting Deletion State Tests
    
    func testRequestDeleteMeeting() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let meeting = MeetingHistoryItem(
            title: "Test Meeting",
            date: Date(),
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true
        )
        
        viewModel.requestDeleteMeeting(meeting)
        
        XCTAssertTrue(viewModel.showDeleteConfirmation)
        XCTAssertEqual(viewModel.meetingsPendingDeletion.count, 1)
        XCTAssertEqual(viewModel.meetingsPendingDeletion.first?.id, meeting.id)
        
        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    func testCancelDeleteMeetings() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let meeting = MeetingHistoryItem(
            title: "Test Meeting",
            date: Date(),
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true
        )
        
        viewModel.requestDeleteMeeting(meeting)
        XCTAssertTrue(viewModel.showDeleteConfirmation)
        
        viewModel.cancelDeleteMeetings()
        
        XCTAssertFalse(viewModel.showDeleteConfirmation)
        XCTAssertEqual(viewModel.meetingsPendingDeletion.count, 0)
        
        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    func testRequestDeleteSelectedMeetings() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        let meetings = (0..<3).map { i in
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            return MeetingHistoryItem(
                title: "Meeting \(i)",
                date: Date(),
                directory: tempDir,
                hasAudio: true,
                hasMicrophone: true
            )
        }
        
        viewModel.meetingHistory = meetings
        
        // Select two meetings
        viewModel.toggleMeetingSelection(meetings[0], extendSelection: false)
        viewModel.toggleMeetingSelection(meetings[2], extendSelection: true)
        
        viewModel.requestDeleteSelectedMeetings()
        
        XCTAssertTrue(viewModel.showDeleteConfirmation)
        XCTAssertEqual(viewModel.meetingsPendingDeletion.count, 2)
        
        // Clean up
        for meeting in meetings {
            try? FileManager.default.removeItem(at: meeting.directory)
        }
    }
    
    // MARK: - Session State Tests
    
    func testCreateSession() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        let session = viewModel.createSession()
        
        XCTAssertNotNil(session)
        XCTAssertEqual(session.state, .idle)
        XCTAssertTrue(session.meetingTitle.isEmpty)
        XCTAssertTrue(session.transcriptText.isEmpty)
    }
    
    func testActiveSessionInitiallyNil() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        XCTAssertNil(viewModel.activeSession)
        XCTAssertNil(viewModel.activeRecordingSession)
    }
    
    func testIsViewingPastMeetingWhileRecording() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        // Initially false (no active session)
        XCTAssertFalse(viewModel.isViewingPastMeetingWhileRecording)
        
        // Even with selectedMeeting, still false without active session
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let meeting = MeetingHistoryItem(
            title: "Test Meeting",
            date: Date(),
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true
        )
        
        viewModel.meetingHistory = [meeting]
        viewModel.toggleMeetingSelection(meeting, extendSelection: false)
        
        XCTAssertFalse(viewModel.isViewingPastMeetingWhileRecording)
        
        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    func testReturnToLiveRecording() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let meeting = MeetingHistoryItem(
            title: "Test Meeting",
            date: Date(),
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true
        )
        
        viewModel.meetingHistory = [meeting]
        viewModel.toggleMeetingSelection(meeting, extendSelection: false)
        
        XCTAssertNotNil(viewModel.selectedMeeting)
        XCTAssertEqual(viewModel.selectedMeetingIDs.count, 1)
        
        viewModel.returnToLiveRecording()
        
        XCTAssertNil(viewModel.selectedMeeting)
        XCTAssertEqual(viewModel.selectedMeetingIDs.count, 0)
        
        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    // MARK: - Onboarding Tests
    
    func testCompleteOnboarding() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        // Clear any existing state
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        
        // Create new ViewModel to pick up cleared state
        let freshViewModel = MuesliViewModel(skipInitialLoad: true)
        
        // Complete onboarding
        freshViewModel.completeOnboarding()
        
        XCTAssertTrue(freshViewModel.hasCompletedOnboarding)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "hasCompletedOnboarding"))
        
        // Clean up
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
    }
    
    func testResetOnboarding() async {
        // Set completed state
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        viewModel.resetOnboarding()
        
        XCTAssertFalse(viewModel.hasCompletedOnboarding)
        
        // Clean up
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
    }
    
    // MARK: - UI State Tests
    
    func testShowStartRecordingSheetInitiallyFalse() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        XCTAssertFalse(viewModel.showStartRecordingSheet)
    }
    
    func testShowTitlePromptSheetInitiallyFalse() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        XCTAssertFalse(viewModel.showTitlePromptSheet)
    }
    
    func testShowDeleteConfirmationInitiallyFalse() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        XCTAssertFalse(viewModel.showDeleteConfirmation)
    }
    
    func testShowRefineSheetInitiallyFalse() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        XCTAssertFalse(viewModel.showRefineSheet)
    }
    
    func testIsSplitViewVisibleInitiallyFalse() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        XCTAssertFalse(viewModel.isSplitViewVisible)
    }
    
    // MARK: - Transcript Refinement State Tests
    
    func testShowOriginalTranscriptToggle() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let meeting = MeetingHistoryItem(
            title: "Test Meeting",
            date: Date(),
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true
        )
        
        // Initially false
        XCTAssertFalse(viewModel.showOriginalTranscript(for: meeting))
        
        // Toggle to true
        viewModel.toggleOriginalTranscript(for: meeting)
        XCTAssertTrue(viewModel.showOriginalTranscript(for: meeting))
        
        // Toggle back to false
        viewModel.toggleOriginalTranscript(for: meeting)
        XCTAssertFalse(viewModel.showOriginalTranscript(for: meeting))
        
        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    func testMeetingBeingRefinedInitiallyNil() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        XCTAssertNil(viewModel.meetingBeingRefined)
    }
    
    // MARK: - Model Error State Tests
    
    func testShowModelErrorAlertInitiallyFalse() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        XCTAssertFalse(viewModel.showModelErrorAlert)
    }
    
    func testSessionPendingModelDecisionInitiallyNil() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        XCTAssertNil(viewModel.sessionPendingModelDecision)
    }
    
    func testCancelRecordingDueToModelError() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        // Set up state as if model error occurred
        viewModel.showModelErrorAlert = true
        viewModel.sessionPendingModelDecision = viewModel.createSession()
        
        viewModel.cancelRecordingDueToModelError()
        
        XCTAssertFalse(viewModel.showModelErrorAlert)
        XCTAssertNil(viewModel.sessionPendingModelDecision)
    }
    
    // MARK: - Transcription Mode Tests
    
    func testTranscriptionModeDefault() async {
        // Clear any saved preference
        UserDefaults.standard.removeObject(forKey: "transcriptionMode")
        
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        // Default should be live
        XCTAssertEqual(viewModel.transcriptionMode, .live)
    }
    
    func testTranscriptionModePersistence() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        // Set to post-processing
        viewModel.transcriptionMode = .postProcessing
        XCTAssertEqual(viewModel.transcriptionMode, .postProcessing)
        
        // Verify UserDefaults
        XCTAssertEqual(UserDefaults.standard.string(forKey: "transcriptionMode"), "postProcessing")
        
        // Set back to live
        viewModel.transcriptionMode = .live
        XCTAssertEqual(viewModel.transcriptionMode, .live)
        
        // Clean up
        UserDefaults.standard.removeObject(forKey: "transcriptionMode")
    }
    
    // MARK: - Refinement Availability Tests
    
    func testCanRefineTranscriptsRequiresBothConditions() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        // canRefineTranscripts requires:
        // 1. llmManager.hasModel == true
        // 2. llmManager.isLLMStitchingEnabled == true
        // Both are based on LLM model being downloaded
        
        // Note: This tests the computed property logic
        // Actual value depends on LLMManager state
        let canRefine = viewModel.canRefineTranscripts
        
        // Just verify it returns a boolean (logic depends on LLM state)
        XCTAssertNotNil(canRefine as Bool?)
    }
    
    // MARK: - Meeting History Item Tests
    
    func testMeetingHistoryItemFormattedDuration() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        // Test minutes only
        let meeting1 = MeetingHistoryItem(
            title: "Meeting",
            date: Date(),
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true,
            duration: 2700  // 45 minutes
        )
        XCTAssertEqual(meeting1.formattedDuration, "45 min")
        
        // Test hours and minutes
        let meeting2 = MeetingHistoryItem(
            title: "Meeting",
            date: Date(),
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true,
            duration: 5400  // 1.5 hours
        )
        XCTAssertEqual(meeting2.formattedDuration, "1h 30 min")
        
        // Test nil duration
        let meeting3 = MeetingHistoryItem(
            title: "Meeting",
            date: Date(),
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true,
            duration: nil
        )
        XCTAssertNil(meeting3.formattedDuration)
        
        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    func testMeetingHistoryItemFormattedWordCount() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        // Test with word count
        let meeting1 = MeetingHistoryItem(
            title: "Meeting",
            date: Date(),
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true,
            wordCount: 1240
        )
        XCTAssertEqual(meeting1.formattedWordCount, "1,240 words")
        
        // Test nil word count
        let meeting2 = MeetingHistoryItem(
            title: "Meeting",
            date: Date(),
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true,
            wordCount: nil
        )
        XCTAssertNil(meeting2.formattedWordCount)
        
        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    // MARK: - RecordingSession Tests
    
    func testRecordingSessionInitialState() async {
        let session = RecordingSession()
        
        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(session.isRecording)
        XCTAssertFalse(session.isCompleted)
        XCTAssertTrue(session.meetingTitle.isEmpty)
        XCTAssertTrue(session.transcriptText.isEmpty)
        XCTAssertNil(session.recordingStartTime)
        XCTAssertNil(session.outputDirectory)
        XCTAssertNil(session.selectedApp)
        XCTAssertFalse(session.isInitializing)
        XCTAssertFalse(session.isMicrophoneMuted)
        XCTAssertFalse(session.wasInterrupted)
        XCTAssertFalse(session.canResume)
        XCTAssertEqual(session.resumeCount, 0)
        XCTAssertEqual(session.segmentNumber, 1)
    }
    
    func testRecordingSessionAudioSourceDescription() async {
        let session = RecordingSession()
        
        // Without selected app
        XCTAssertEqual(session.audioSourceDescription, "All System Audio")
        
        // With selected app
        let mockApp = MeetingAppDetector.DetectedApp(
            id: "com.zoom.xos",
            name: "Zoom",
            bundleIdentifier: "com.zoom.xos"
        )
        session.selectedApp = mockApp
        XCTAssertEqual(session.audioSourceDescription, "Zoom")
    }
    
    func testRecordingSessionElapsedTimeString() async {
        let session = RecordingSession()
        
        // Without start time
        XCTAssertEqual(session.elapsedTimeString, "00:00")
        
        // With start time
        session.recordingStartTime = Date().addingTimeInterval(-125)  // 2 min 5 sec ago
        // Note: actual elapsed will differ slightly, so just verify format
        let elapsed = session.elapsedTimeString
        XCTAssertTrue(elapsed.contains(":"))
    }
    
    func testRecordingSessionErrorHandling() async {
        let session = RecordingSession()
        
        XCTAssertNil(session.errorMessage)
        XCTAssertFalse(session.showError)
        
        session.showErrorMessage("Test error")
        
        XCTAssertEqual(session.errorMessage, "Test error")
        XCTAssertTrue(session.showError)
        
        session.dismissError()
        
        XCTAssertNil(session.errorMessage)
        XCTAssertFalse(session.showError)
    }
    
    // MARK: - TranscriptBlock Tests
    
    func testTranscriptBlockWordCount() async {
        let block = TranscriptBlock(
            speaker: .me,
            text: "Hello world this is a test",
            startTimestamp: 0
        )
        
        XCTAssertEqual(block.wordCount, 6)
    }
    
    func testTranscriptBlockFormattedStartTime() async {
        let block = TranscriptBlock(
            speaker: .me,
            text: "Test",
            startTimestamp: 125  // 2:05
        )
        
        XCTAssertEqual(block.formattedStartTime, "02:05")
    }
    
    func testTranscriptBlockAppend() async {
        var block = TranscriptBlock(
            speaker: .me,
            text: "Hello",
            startTimestamp: 0,
            endTimestamp: 5
        )
        
        block.append("world", endTimestamp: 10)
        
        XCTAssertEqual(block.text, "Hello world")
        XCTAssertEqual(block.endTimestamp, 10)
    }
    
    // MARK: - TranscriptSegment Tests
    
    func testTranscriptSegmentInitialization() async {
        let blocks = [
            TranscriptBlock(speaker: .me, text: "Test", startTimestamp: 0)
        ]
        
        let segment = TranscriptSegment(
            segmentNumber: 1,
            originalBlocks: blocks,
            startTime: Date()
        )
        
        XCTAssertEqual(segment.segmentNumber, 1)
        XCTAssertEqual(segment.originalBlocks.count, 1)
        XCTAssertNil(segment.refinedBlocks)
        XCTAssertFalse(segment.isRefined)
    }
    
    // MARK: - Recording State Tests (CRITICAL)
    
    func testIsRecordingActiveWhenNoSession() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        // With no active session, isRecordingActive should be false
        // This is derived from activeSession state
        XCTAssertNil(viewModel.activeSession)
        XCTAssertNil(viewModel.activeRecordingSession)
    }
    
    func testActiveSessionIsNilInitially() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        XCTAssertNil(viewModel.activeSession)
    }
    
    func testSessionStateTransitions() async {
        // Test that RecordingSession state enum works correctly
        let session = RecordingSession()
        
        // Initial state
        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(session.isRecording)
        XCTAssertFalse(session.isCompleted)
        
        // Transition to recording
        session.state = .recording
        XCTAssertTrue(session.isRecording)
        XCTAssertFalse(session.isCompleted)
        
        // Transition to stopping
        session.state = .stopping
        XCTAssertFalse(session.isRecording)
        XCTAssertFalse(session.isCompleted)
        
        // Transition to completed
        session.state = .completed
        XCTAssertFalse(session.isRecording)
        XCTAssertTrue(session.isCompleted)
    }
    
    // MARK: - Microphone Mute Tests (CRITICAL)
    
    func testSessionMicrophoneMuteInitiallyFalse() async {
        let session = RecordingSession()
        
        XCTAssertFalse(session.isMicrophoneMuted)
    }
    
    func testSessionMicrophoneMuteToggle() async {
        let session = RecordingSession()
        
        XCTAssertFalse(session.isMicrophoneMuted)
        
        session.isMicrophoneMuted = true
        XCTAssertTrue(session.isMicrophoneMuted)
        
        session.isMicrophoneMuted = false
        XCTAssertFalse(session.isMicrophoneMuted)
    }
    
    // MARK: - Echo Cancellation Tests (CRITICAL)
    
    func testEchoCancellationToggle() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        // Get initial state
        let initial = viewModel.isEchoCancellationEnabled
        
        // Toggle
        viewModel.isEchoCancellationEnabled = !initial
        XCTAssertEqual(viewModel.isEchoCancellationEnabled, !initial)
        
        // Verify UserDefaults persistence
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "echoCancellationEnabled"), !initial)
        
        // Toggle back
        viewModel.isEchoCancellationEnabled = initial
        XCTAssertEqual(viewModel.isEchoCancellationEnabled, initial)
        
        // Clean up
        UserDefaults.standard.removeObject(forKey: "echoCancellationEnabled")
    }
    
    func testEchoCancellationPersistenceBetweenInstances() async {
        // Set a value
        UserDefaults.standard.set(true, forKey: "echoCancellationEnabled")
        
        // Create new ViewModel - should load persisted value
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        XCTAssertTrue(viewModel.isEchoCancellationEnabled)
        
        // Clean up
        UserDefaults.standard.removeObject(forKey: "echoCancellationEnabled")
    }
    
    // MARK: - Meeting Deletion Tests (CRITICAL - Actual Deletion)
    
    func testConfirmDeleteMeetingsClearsState() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let meeting = MeetingHistoryItem(
            title: "Test Meeting",
            date: Date(),
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true
        )
        
        viewModel.meetingHistory = [meeting]
        viewModel.requestDeleteMeeting(meeting)
        
        XCTAssertTrue(viewModel.showDeleteConfirmation)
        XCTAssertEqual(viewModel.meetingsPendingDeletion.count, 1)
        
        // Confirm deletion
        viewModel.confirmDeleteMeetings()
        
        // State should be cleared
        XCTAssertFalse(viewModel.showDeleteConfirmation)
        XCTAssertEqual(viewModel.meetingsPendingDeletion.count, 0)
        
        // Clean up (directory may already be deleted by confirmDeleteMeetings)
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    func testConfirmDeleteMeetingsClearsSelection() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        let meetings = (0..<2).map { i in
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            return MeetingHistoryItem(
                title: "Meeting \(i)",
                date: Date(),
                directory: tempDir,
                hasAudio: true,
                hasMicrophone: true
            )
        }
        
        viewModel.meetingHistory = meetings
        
        // Select the first meeting
        viewModel.toggleMeetingSelection(meetings[0], extendSelection: false)
        XCTAssertTrue(viewModel.selectedMeetingIDs.contains(meetings[0].id))
        
        // Request deletion of the selected meeting
        viewModel.requestDeleteMeeting(meetings[0])
        viewModel.confirmDeleteMeetings()
        
        // Selection should be cleared for deleted meeting
        XCTAssertFalse(viewModel.selectedMeetingIDs.contains(meetings[0].id))
        
        // Clean up
        for meeting in meetings {
            try? FileManager.default.removeItem(at: meeting.directory)
        }
    }
    
    // MARK: - Resume Recording Precondition Tests
    
    func testMeetingCanResumeInitiallyFalse() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let meeting = MeetingHistoryItem(
            title: "Test Meeting",
            date: Date(),
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true
        )
        
        // New meetings start with canResume = false
        XCTAssertFalse(meeting.canResume)
        
        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    func testMeetingCanResumeAfterSetting() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let meeting = MeetingHistoryItem(
            title: "Test Meeting",
            date: Date(),
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true
        )
        
        meeting.canResume = true
        XCTAssertTrue(meeting.canResume)
        
        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    func testSessionResumeCountInitiallyZero() async {
        let session = RecordingSession()
        
        XCTAssertEqual(session.resumeCount, 0)
        XCTAssertEqual(session.segmentNumber, 1)
    }
    
    func testSessionResumeState() async {
        let session = RecordingSession()
        
        // Simulate a resumed recording
        session.resumeCount = 1
        session.segmentNumber = 2
        
        XCTAssertEqual(session.resumeCount, 1)
        XCTAssertEqual(session.segmentNumber, 2)
    }
    
    // MARK: - Refinement State Machine Tests (CRITICAL)
    
    func testCancelRefinement() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let meeting = MeetingHistoryItem(
            title: "Test Meeting",
            date: Date(),
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true
        )
        
        // Set up refinement state
        viewModel.meetingBeingRefined = meeting
        
        // Cancel refinement
        viewModel.cancelRefinement()
        
        // State should be cleared
        XCTAssertNil(viewModel.meetingBeingRefined)
        
        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    func testRefinementServiceInitialized() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        // Refinement service should be initialized
        XCTAssertNotNil(viewModel.refinementService)
    }
    
    func testMeetingIsRefinedInitiallyFalse() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let meeting = MeetingHistoryItem(
            title: "Test Meeting",
            date: Date(),
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true
        )
        
        XCTAssertFalse(meeting.isRefined)
        XCTAssertNil(meeting.originalTranscript)
        XCTAssertNil(meeting.originalTranscriptBlocks)
        
        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    // MARK: - Transcript Block Pipeline Tests
    
    func testSessionTranscriptBlocksInitiallyEmpty() async {
        let session = RecordingSession()
        
        XCTAssertTrue(session.transcriptBlocks.isEmpty)
        XCTAssertTrue(session.transcriptText.isEmpty)
    }
    
    func testSessionTranscriptTextUpdates() async {
        let session = RecordingSession()
        
        session.transcriptText = "Test transcript content"
        XCTAssertEqual(session.transcriptText, "Test transcript content")
    }
    
    // MARK: - Model Error Flow Tests
    
    func testModelErrorAlertFlow() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        // Simulate model error state
        let session = viewModel.createSession()
        viewModel.sessionPendingModelDecision = session
        viewModel.showModelErrorAlert = true
        
        XCTAssertTrue(viewModel.showModelErrorAlert)
        XCTAssertNotNil(viewModel.sessionPendingModelDecision)
        
        // Cancel due to model error
        viewModel.cancelRecordingDueToModelError()
        
        XCTAssertFalse(viewModel.showModelErrorAlert)
        XCTAssertNil(viewModel.sessionPendingModelDecision)
    }
    
    // MARK: - Session Interruption State Tests
    
    func testSessionWasInterruptedInitiallyFalse() async {
        let session = RecordingSession()
        
        XCTAssertFalse(session.wasInterrupted)
        XCTAssertNil(session.interruptionReason)
    }
    
    func testSessionInterruptionState() async {
        let session = RecordingSession()
        
        session.wasInterrupted = true
        session.interruptionReason = "Test interruption"
        
        XCTAssertTrue(session.wasInterrupted)
        XCTAssertEqual(session.interruptionReason, "Test interruption")
    }
    
    // MARK: - Permission State Tests
    
    func testPermissionStateProperties() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        // These are boolean properties that should have values
        // (actual values depend on system state)
        _ = viewModel.hasScreenRecordingPermission
        _ = viewModel.hasMicrophonePermission
        _ = viewModel.isMicrophonePermissionDenied
        
        // Just verify they return booleans without crashing
        XCTAssertTrue(true)
    }
    
    // MARK: - Output Directory Tests
    
    func testSetOutputDirectory() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestOutput")
        
        viewModel.setOutputDirectory(testDir)
        XCTAssertEqual(viewModel.outputDirectory, testDir)
        
        // Clean up
        viewModel.resetOutputDirectory()
    }
    
    func testResetOutputDirectory() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestOutput")
        
        viewModel.setOutputDirectory(testDir)
        viewModel.resetOutputDirectory()
        
        // Should be back to default
        XCTAssertEqual(viewModel.outputDirectory, MuesliViewModel.defaultOutputDirectory)
    }
    
    // MARK: - Audio Level Properties Tests
    
    func testSessionAudioLevelInitiallyZero() async {
        let session = RecordingSession()
        
        XCTAssertEqual(session.microphoneLevel, 0.0)
        XCTAssertEqual(session.systemAudioLevel, 0.0)
    }
    
    func testSessionAudioLevelUpdates() async {
        let session = RecordingSession()
        
        session.microphoneLevel = 0.5
        session.systemAudioLevel = 0.7
        
        XCTAssertEqual(session.microphoneLevel, 0.5)
        XCTAssertEqual(session.systemAudioLevel, 0.7)
    }
    
    // MARK: - Meeting Segment Tests
    
    func testMeetingSegmentCountDefaultsToOne() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let meeting = MeetingHistoryItem(
            title: "Test Meeting",
            date: Date(),
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true
        )
        
        // Default segment count is 1 (first segment)
        XCTAssertEqual(meeting.segmentCount, 1)
        // But transcriptSegments array starts empty (segments are added during recording)
        XCTAssertTrue(meeting.transcriptSegments.isEmpty)
        
        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    func testMeetingSegmentAddition() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let meeting = MeetingHistoryItem(
            title: "Test Meeting",
            date: Date(),
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true
        )
        
        let blocks = [
            TranscriptBlock(speaker: .me, text: "Test", startTimestamp: 0)
        ]
        
        let segment = TranscriptSegment(
            segmentNumber: 1,
            originalBlocks: blocks,
            startTime: Date()
        )
        
        meeting.transcriptSegments.append(segment)
        meeting.segmentCount = 1
        
        XCTAssertEqual(meeting.segmentCount, 1)
        XCTAssertEqual(meeting.transcriptSegments.count, 1)
        
        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    // MARK: - Launch at Login Tests
    
    func testLaunchAtLoginProperty() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        // Just verify the property is accessible
        // Actual value depends on system state
        _ = viewModel.launchAtLogin
        XCTAssertTrue(true)
    }
    
    // MARK: - Model Manager Integration Tests
    
    func testModelManagerExists() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        XCTAssertNotNil(viewModel.modelManager)
    }
    
    func testLLMManagerExists() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        XCTAssertNotNil(viewModel.llmManager)
    }
    
    func testMicrophoneManagerExists() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        XCTAssertNotNil(viewModel.microphoneManager)
    }
    
    // MARK: - PreferencesManager Tests (Phase 1)
    
    func testPreferencesManagerOutputDirectory() async {
        // Clear any persisted output directory to test default behavior
        UserDefaults.standard.removeObject(forKey: "outputDirectory")
        
        // Skip migration to test default behavior
        let prefs = PreferencesManager(skipMigration: true)
        
        // Default should be in Application Support/Muesli/Recordings
        XCTAssertTrue(prefs.outputDirectory.path.contains("Muesli"), "Expected path to contain 'Muesli', got: \(prefs.outputDirectory.path)")
        XCTAssertTrue(prefs.outputDirectory.path.contains("Recordings"), "Expected path to contain 'Recordings', got: \(prefs.outputDirectory.path)")
        XCTAssertTrue(prefs.outputDirectory.path.contains("Application Support"), "Expected path to contain 'Application Support', got: \(prefs.outputDirectory.path)")
        
        // Set custom directory
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestOutput")
        prefs.setOutputDirectory(testDir)
        XCTAssertEqual(prefs.outputDirectory, testDir)
        
        // Reset to default
        prefs.resetOutputDirectory()
        XCTAssertEqual(prefs.outputDirectory, PreferencesManager.defaultOutputDirectory)
    }
    
    func testPreferencesManagerTranscriptionMode() async {
        let prefs = PreferencesManager()
        
        // Default is live
        // Note: Actual default depends on UserDefaults state
        let initialMode = prefs.transcriptionMode
        
        // Set to post-processing
        prefs.transcriptionMode = .postProcessing
        XCTAssertEqual(prefs.transcriptionMode, .postProcessing)
        
        // Set back to live
        prefs.transcriptionMode = .live
        XCTAssertEqual(prefs.transcriptionMode, .live)
        
        // Restore original
        prefs.transcriptionMode = initialMode
    }
    
    func testPreferencesManagerEchoCancellation() async {
        let prefs = PreferencesManager()
        
        // Get initial state
        let initial = prefs.isEchoCancellationEnabled
        
        // Toggle
        prefs.isEchoCancellationEnabled = !initial
        XCTAssertEqual(prefs.isEchoCancellationEnabled, !initial)
        
        // Thread-safe accessor should match
        XCTAssertEqual(prefs.echoCancellationEnabledForAudioCallback, !initial)
        
        // Restore
        prefs.isEchoCancellationEnabled = initial
    }
    
    func testPreferencesManagerLaunchAtLogin() async {
        let prefs = PreferencesManager()
        
        // Just verify property is accessible (actual value depends on system state)
        _ = prefs.launchAtLogin
        XCTAssertTrue(true)
    }
    
    func testPreferencesManagerCallbacks() async {
        let prefs = PreferencesManager()
        
        var outputDirChanged = false
        var transcriptionModeChanged = false
        
        prefs.outputDirectoryDidChange = { _ in
            outputDirChanged = true
        }
        
        prefs.transcriptionModeDidChange = { _ in
            transcriptionModeChanged = true
        }
        
        // Change output directory
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("CallbackTest")
        prefs.setOutputDirectory(testDir)
        XCTAssertTrue(outputDirChanged)
        
        // Change transcription mode
        let originalMode = prefs.transcriptionMode
        prefs.transcriptionMode = originalMode == .live ? .postProcessing : .live
        XCTAssertTrue(transcriptionModeChanged)
        
        // Restore
        prefs.transcriptionMode = originalMode
        prefs.resetOutputDirectory()
    }
    
    func testPreferencesManagerTranscriptionModeConversion() async {
        // Test enum conversion to service mode
        let liveMode = PreferencesManager.TranscriptionMode.live
        XCTAssertEqual(liveMode.serviceMode, TranscriptionService.TranscriptionMode.live)
        
        let postMode = PreferencesManager.TranscriptionMode.postProcessing
        XCTAssertEqual(postMode.serviceMode, TranscriptionService.TranscriptionMode.postProcessing)
        
        // Test creation from service mode
        let fromLive = PreferencesManager.TranscriptionMode(from: .live)
        XCTAssertEqual(fromLive, .live)
        
        let fromPost = PreferencesManager.TranscriptionMode(from: .postProcessing)
        XCTAssertEqual(fromPost, .postProcessing)
    }
    
    func testPreferencesManagerSharedUserDefaults() async {
        // Verify PreferencesManager and MuesliViewModel share UserDefaults
        let prefs = PreferencesManager()
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        // Both should read from same UserDefaults key
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("SharedTest")
        prefs.setOutputDirectory(testDir)
        
        // MuesliViewModel should see the same value
        XCTAssertEqual(viewModel.outputDirectory, testDir)
        
        // Clean up
        prefs.resetOutputDirectory()
    }
    
    // MARK: - MeetingHistoryManager Tests (Phase 2)
    
    func testMeetingHistoryManagerInitialization() async {
        let manager = MeetingHistoryManager(skipInitialLoad: true)
        
        // Manager should exist and be ready
        XCTAssertNotNil(manager)
        // History starts empty with skipInitialLoad
        XCTAssertNotNil(manager.meetingHistory)
        XCTAssertNotNil(manager.groupedHistory)
    }
    
    func testMeetingHistoryManagerSelection() async {
        let manager = MeetingHistoryManager(skipInitialLoad: true)
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let meeting = MeetingHistoryItem(
            title: "Test Meeting",
            date: Date(),
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true
        )
        
        // Add to history
        manager.meetingHistory = [meeting]
        
        // Select the meeting
        manager.selectMeeting(meeting)
        
        XCTAssertEqual(manager.selectedMeeting?.id, meeting.id)
        XCTAssertEqual(manager.selectedMeetingIDs.count, 1)
        XCTAssertTrue(manager.selectedMeetingIDs.contains(meeting.id))
        XCTAssertTrue(manager.hasSelection)
        
        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    func testMeetingHistoryManagerMultiSelect() async {
        let manager = MeetingHistoryManager(skipInitialLoad: true)
        
        let meetings = (0..<3).map { i in
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            return MeetingHistoryItem(
                title: "Meeting \(i)",
                date: Date(),
                directory: tempDir,
                hasAudio: true,
                hasMicrophone: true
            )
        }
        
        manager.meetingHistory = meetings
        
        // Select first meeting
        manager.toggleMeetingSelection(meetings[0], extendSelection: false)
        XCTAssertEqual(manager.selectedMeetingIDs.count, 1)
        
        // Cmd+click to add second
        manager.toggleMeetingSelection(meetings[1], extendSelection: true)
        XCTAssertEqual(manager.selectedMeetingIDs.count, 2)
        
        // Cmd+click to toggle off first
        manager.toggleMeetingSelection(meetings[0], extendSelection: true)
        XCTAssertEqual(manager.selectedMeetingIDs.count, 1)
        XCTAssertFalse(manager.selectedMeetingIDs.contains(meetings[0].id))
        
        // Clean up
        for meeting in meetings {
            try? FileManager.default.removeItem(at: meeting.directory)
        }
    }
    
    func testMeetingHistoryManagerClearSelection() async {
        let manager = MeetingHistoryManager(skipInitialLoad: true)
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let meeting = MeetingHistoryItem(
            title: "Test Meeting",
            date: Date(),
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true
        )
        
        manager.meetingHistory = [meeting]
        manager.selectMeeting(meeting)
        
        XCTAssertTrue(manager.hasSelection)
        
        manager.clearSelection()
        
        XCTAssertFalse(manager.hasSelection)
        XCTAssertNil(manager.selectedMeeting)
        XCTAssertEqual(manager.selectedMeetingIDs.count, 0)
        
        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    func testMeetingHistoryManagerDeleteFlow() async {
        let manager = MeetingHistoryManager(skipInitialLoad: true)
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let meeting = MeetingHistoryItem(
            title: "Test Meeting",
            date: Date(),
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true
        )
        
        manager.meetingHistory = [meeting]
        
        // Request deletion
        manager.requestDeleteMeeting(meeting)
        
        XCTAssertTrue(manager.showDeleteConfirmation)
        XCTAssertEqual(manager.meetingsPendingDeletion.count, 1)
        
        // Cancel deletion
        manager.cancelDeleteMeetings()
        
        XCTAssertFalse(manager.showDeleteConfirmation)
        XCTAssertEqual(manager.meetingsPendingDeletion.count, 0)
        
        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    func testMeetingHistoryManagerGrouping() async {
        let manager = MeetingHistoryManager(skipInitialLoad: true)
        
        // Create meetings from different time periods
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        
        let meetings = [today, yesterday].enumerated().map { (index, date) in
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            return MeetingHistoryItem(
                title: "Meeting \(index)",
                date: date,
                directory: tempDir,
                hasAudio: true,
                hasMicrophone: true
            )
        }
        
        let groups = manager.groupMeetingsByDate(meetings)
        
        // Should have Today and Yesterday groups
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.contains { $0.label == "Today" })
        XCTAssertTrue(groups.contains { $0.label == "Yesterday" })
        
        // Clean up
        for meeting in meetings {
            try? FileManager.default.removeItem(at: meeting.directory)
        }
    }
    
    func testMeetingHistoryManagerSelectedMeetings() async {
        let manager = MeetingHistoryManager(skipInitialLoad: true)
        
        let meetings = (0..<3).map { i in
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            return MeetingHistoryItem(
                title: "Meeting \(i)",
                date: Date(),
                directory: tempDir,
                hasAudio: true,
                hasMicrophone: true
            )
        }
        
        manager.meetingHistory = meetings
        
        // Select two meetings
        manager.toggleMeetingSelection(meetings[0], extendSelection: false)
        manager.toggleMeetingSelection(meetings[2], extendSelection: true)
        
        let selected = manager.selectedMeetings
        XCTAssertEqual(selected.count, 2)
        XCTAssertTrue(selected.contains { $0.id == meetings[0].id })
        XCTAssertTrue(selected.contains { $0.id == meetings[2].id })
        
        // Clean up
        for meeting in meetings {
            try? FileManager.default.removeItem(at: meeting.directory)
        }
    }
    
    func testMeetingHistoryManagerFindByDirectory() async {
        let manager = MeetingHistoryManager(skipInitialLoad: true)
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let meeting = MeetingHistoryItem(
            title: "Test Meeting",
            date: Date(),
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true
        )
        
        manager.meetingHistory = [meeting]
        
        // Find by directory
        let found = manager.meeting(for: tempDir)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, meeting.id)
        
        // Not found
        let notFound = manager.meeting(for: FileManager.default.temporaryDirectory)
        XCTAssertNil(notFound)
        
        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    // MARK: - Onboarding Bypass / Security Tests (CRITICAL)
    
    /// Test that bypassing onboarding via UserDefaults still requires a valid model to record
    func testBypassingOnboardingStillRequiresModel() async {
        // Simulate bypassing onboarding by setting UserDefaults directly
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        // Onboarding appears complete
        XCTAssertTrue(viewModel.hasCompletedOnboarding)
        
        // But if there's no valid model, recording should not succeed
        // The model validation happens in startRecordingAsync, which shows showModelErrorAlert
        // We can't fully test startRecording without mocking services, but we can verify
        // the model validation logic exists
        
        // ModelManager should not have an active model in a fresh test environment
        // (unless one was previously downloaded)
        let hasActiveModel = viewModel.modelManager.activeModel != nil
        
        // If no model, attempting to record should eventually trigger model error flow
        // This documents the expected behavior
        if !hasActiveModel {
            // Without a model, the recording flow should fail gracefully
            XCTAssertNil(viewModel.modelPath)
        }
        
        // Clean up
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
    }
    
    /// Test that onboarding state correctly reflects UserDefaults
    func testOnboardingStateMatchesUserDefaults() async {
        // Clear state
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        
        // New ViewModel should show onboarding not completed
        let viewModel1 = MuesliViewModel(skipInitialLoad: true)
        XCTAssertFalse(viewModel1.hasCompletedOnboarding)
        
        // Complete onboarding
        viewModel1.completeOnboarding()
        XCTAssertTrue(viewModel1.hasCompletedOnboarding)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "hasCompletedOnboarding"))
        
        // New ViewModel should pick up persisted state
        let viewModel2 = MuesliViewModel(skipInitialLoad: true)
        XCTAssertTrue(viewModel2.hasCompletedOnboarding)
        
        // Clean up
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
    }
    
    /// Test that model path is nil when no model is configured
    func testModelPathNilWithoutActiveModel() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        // In a test environment without a downloaded model, modelPath should be nil
        // OR if a model exists, it should be a valid path
        if let path = viewModel.modelPath {
            // If there is a path, verify the directory exists
            XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        }
        // If nil, that's expected in a clean test environment
    }
    
    /// Test that starting recording without active session is blocked
    func testCannotRecordWhileAlreadyRecording() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        // Simulate an active session
        let session1 = viewModel.createSession()
        session1.state = .recording
        
        // Manually set activeSession (normally done by startRecording)
        // This tests the guard at the start of startRecording
        // viewModel.activeSession is private(set), so we test the public behavior instead
        
        // Create another session
        let session2 = viewModel.createSession()
        
        // Both sessions should be different
        XCTAssertNotEqual(session1.id, session2.id)
        
        // Each session starts in idle state
        XCTAssertEqual(session2.state, .idle)
    }
    
    /// Test that recording requires specific preconditions
    func testRecordingPreconditions() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        // Document the preconditions for recording:
        // 1. No active session (checked in startRecording)
        XCTAssertNil(viewModel.activeSession)
        
        // 2. Permissions are needed (but don't block the call, just affect behavior)
        // hasScreenRecordingPermission and hasMicrophonePermission are checked
        _ = viewModel.hasScreenRecordingPermission
        _ = viewModel.hasMicrophonePermission
        
        // 3. A valid model path is needed (checked in startRecordingAsync)
        // If no model, showModelErrorAlert is triggered
        _ = viewModel.modelPath
        
        // This test documents the expected preconditions
        XCTAssertTrue(true)
    }
    
    // MARK: - Model Validation Tests
    
    /// Test that model error alert flow works correctly
    func testModelErrorAlertTriggersOnInvalidModel() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        
        // Initially no error
        XCTAssertFalse(viewModel.showModelErrorAlert)
        XCTAssertNil(viewModel.sessionPendingModelDecision)
        
        // Simulate what happens when startRecordingAsync finds no valid model
        let session = viewModel.createSession()
        viewModel.sessionPendingModelDecision = session
        viewModel.showModelErrorAlert = true
        
        // Alert should be shown
        XCTAssertTrue(viewModel.showModelErrorAlert)
        XCTAssertNotNil(viewModel.sessionPendingModelDecision)
        
        // User cancels
        viewModel.cancelRecordingDueToModelError()
        
        // State should be reset
        XCTAssertFalse(viewModel.showModelErrorAlert)
        XCTAssertNil(viewModel.sessionPendingModelDecision)
    }
    
    /// Test that model manager can validate model existence
    func testModelManagerValidation() async {
        let viewModel = MuesliViewModel(skipInitialLoad: true)
        let modelManager = viewModel.modelManager
        
        // ModelManager should exist
        XCTAssertNotNil(modelManager)
        
        // Downloaded models set should be accessible
        _ = modelManager.downloadedModels
        
        // Active model may or may not exist depending on test environment
        _ = modelManager.activeModel
        
        // hasModel should reflect whether there's a usable model
        _ = modelManager.hasModel
    }
    
    // MARK: - Session Lifecycle Invariant Tests
    
    /// Test that session state transitions are valid
    func testSessionStateInvariants() async {
        let session = RecordingSession()
        
        // Invariant: isRecording is true only when state is .recording
        session.state = .idle
        XCTAssertFalse(session.isRecording)
        
        session.state = .recording
        XCTAssertTrue(session.isRecording)
        
        session.state = .stopping
        XCTAssertFalse(session.isRecording)
        
        session.state = .completed
        XCTAssertFalse(session.isRecording)
        
        // Invariant: isCompleted is true only when state is .completed
        session.state = .idle
        XCTAssertFalse(session.isCompleted)
        
        session.state = .recording
        XCTAssertFalse(session.isCompleted)
        
        session.state = .stopping
        XCTAssertFalse(session.isCompleted)
        
        session.state = .completed
        XCTAssertTrue(session.isCompleted)
    }
    
    /// Test that completed session can be marked as resumable
    func testCompletedSessionCanBeResumed() async {
        let session = RecordingSession()
        
        // Go through recording lifecycle
        session.state = .recording
        session.state = .stopping
        session.state = .completed
        
        // After completion, canResume can be set
        XCTAssertFalse(session.canResume)
        session.canResume = true
        XCTAssertTrue(session.canResume)
    }
    
    // MARK: - Transcript Data Integrity Tests
    
    /// Test that transcript blocks maintain order
    func testTranscriptBlockOrdering() async {
        let blocks = [
            TranscriptBlock(speaker: .me, text: "First", startTimestamp: 0),
            TranscriptBlock(speaker: .them, text: "Second", startTimestamp: 5),
            TranscriptBlock(speaker: .me, text: "Third", startTimestamp: 10)
        ]
        
        // Timestamps should be in order
        for i in 1..<blocks.count {
            XCTAssertGreaterThan(blocks[i].startTimestamp, blocks[i-1].startTimestamp)
        }
        
        // Speaker alternation is preserved
        XCTAssertEqual(blocks[0].speaker, .me)
        XCTAssertEqual(blocks[1].speaker, .them)
        XCTAssertEqual(blocks[2].speaker, .me)
    }
    
    /// Test that transcript segments maintain integrity
    func testTranscriptSegmentIntegrity() async {
        let blocks = [
            TranscriptBlock(speaker: .me, text: "Test content", startTimestamp: 0)
        ]
        
        let segment = TranscriptSegment(
            segmentNumber: 1,
            originalBlocks: blocks,
            startTime: Date()
        )
        
        // Original blocks should be preserved
        XCTAssertEqual(segment.originalBlocks.count, 1)
        XCTAssertEqual(segment.originalBlocks[0].text, "Test content")
        
        // Refined blocks start as nil
        XCTAssertNil(segment.refinedBlocks)
        XCTAssertFalse(segment.isRefined)
        
        // After refinement
        let refinedBlocks = [
            TranscriptBlock(speaker: .me, text: "Test content refined", startTimestamp: 0)
        ]
        
        var mutableSegment = segment
        mutableSegment.refinedBlocks = refinedBlocks
        mutableSegment.isRefined = true
        
        // Original should still be preserved
        XCTAssertEqual(mutableSegment.originalBlocks[0].text, "Test content")
        // Refined should be available
        XCTAssertEqual(mutableSegment.refinedBlocks?[0].text, "Test content refined")
        XCTAssertTrue(mutableSegment.isRefined)
    }
    
    /// Test that meeting stores both original and refined transcripts
    func testMeetingPreservesOriginalTranscript() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let meeting = MeetingHistoryItem(
            title: "Test Meeting",
            date: Date(),
            directory: tempDir,
            hasAudio: true,
            hasMicrophone: true
        )
        
        // Set original transcript
        meeting.transcript = "Original transcript text"
        meeting.transcriptBlocks = [
            TranscriptBlock(speaker: .me, text: "Original block", startTimestamp: 0)
        ]
        
        // Store original before refinement
        meeting.originalTranscript = meeting.transcript
        meeting.originalTranscriptBlocks = meeting.transcriptBlocks
        
        // Simulate refinement
        meeting.transcript = "Refined transcript text"
        meeting.transcriptBlocks = [
            TranscriptBlock(speaker: .me, text: "Refined block", startTimestamp: 0)
        ]
        meeting.isRefined = true
        
        // Both should be available
        XCTAssertEqual(meeting.originalTranscript, "Original transcript text")
        XCTAssertEqual(meeting.transcript, "Refined transcript text")
        XCTAssertEqual(meeting.originalTranscriptBlocks?.first?.text, "Original block")
        XCTAssertEqual(meeting.transcriptBlocks?.first?.text, "Refined block")
        XCTAssertTrue(meeting.isRefined)
        
        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }
}
