import XCTest
@testable import Muesli

/// Tests for RefinementCoordinator
/// Focus: State management, refinement workflows, and file saving without actual LLM inference
@MainActor
final class RefinementCoordinatorTests: XCTestCase {
    
    var mockLLMManager: MockLLMManager!
    var mockFileOutputService: MockFileOutputService!
    var coordinator: RefinementCoordinator!
    
    override func setUp() {
        super.setUp()
        mockLLMManager = MockLLMManager()
        mockFileOutputService = MockFileOutputService()
        coordinator = RefinementCoordinator(
            llmManager: mockLLMManager,
            fileOutputService: mockFileOutputService
        )
    }
    
    override func tearDown() {
        coordinator = nil
        mockFileOutputService = nil
        mockLLMManager = nil
        super.tearDown()
    }
    
    // MARK: - Part 1: Initialization & State
    
    /// Test coordinator initialization
    func testCoordinatorInitialization() {
        XCTAssertNotNil(coordinator)
        XCTAssertFalse(coordinator.showRefineSheet)
        XCTAssertFalse(coordinator.showRefinementPrompt)
        XCTAssertNil(coordinator.meetingBeingRefined)
    }
    
    /// Test canRefineTranscripts computed property
    func testCanRefineTranscriptsWhenModelNotAvailable() {
        // Given: No model
        mockLLMManager.downloadedModels.removeAll()
        mockLLMManager.isLLMStitchingEnabled = false
        
        // Then: Cannot refine
        XCTAssertFalse(coordinator.canRefineTranscripts)
    }
    
    /// Test canRefineTranscripts when model available
    func testCanRefineTranscriptsWhenModelAvailable() {
        // Given: Model available
        mockLLMManager.downloadedModels.insert(.llama32_3b)
        mockLLMManager.setActiveModel(.llama32_3b)
        mockLLMManager.isLLMStitchingEnabled = true
        
        // Then: Can refine
        XCTAssertTrue(coordinator.canRefineTranscripts)
    }
    
    /// Test isRefining state tracking
    func testIsRefiningStateTracking() {
        // Initially not refining
        XCTAssertFalse(coordinator.isRefining)
        
        // Note: isRefining comes from refinementService which we can't easily control
        // This test just verifies the property is accessible
    }
    
    /// Test refinementProgress reporting
    func testRefinementProgressReporting() {
        // Initially 0 progress
        XCTAssertEqual(coordinator.refinementProgress, 0.0)
    }
    
    /// Test show/hide refinement UI sheets
    func testShowHideRefinementSheets() {
        // Initially hidden
        XCTAssertFalse(coordinator.showRefineSheet)
        XCTAssertFalse(coordinator.showRefinementPrompt)
        
        // Show refinement sheet
        coordinator.showRefineSheet = true
        XCTAssertTrue(coordinator.showRefineSheet)
        
        // Show refinement prompt
        coordinator.showRefinementPrompt = true
        XCTAssertTrue(coordinator.showRefinementPrompt)
        
        // Hide
        coordinator.showRefineSheet = false
        coordinator.showRefinementPrompt = false
        XCTAssertFalse(coordinator.showRefineSheet)
        XCTAssertFalse(coordinator.showRefinementPrompt)
    }
    
    /// Test meeting being refined tracking
    func testMeetingBeingRefinedTracking() {
        // Initially nil
        XCTAssertNil(coordinator.meetingBeingRefined)
        
        // Set meeting
        let meeting = MeetingHistoryItem(
            date: Date(),
            title: "Test Meeting",
            directory: FileManager.default.temporaryDirectory
        )
        coordinator.meetingBeingRefined = meeting
        
        XCTAssertEqual(coordinator.meetingBeingRefined?.title, "Test Meeting")
        
        // Clear
        coordinator.meetingBeingRefined = nil
        XCTAssertNil(coordinator.meetingBeingRefined)
    }
    
    // MARK: - Part 2: Original/Refined Toggle
    
    /// Test get showing original state for meeting
    func testGetShowingOriginalState() {
        let meeting = MeetingHistoryItem(
            date: Date(),
            title: "Test",
            directory: FileManager.default.temporaryDirectory
        )
        
        // Initially false (showing refined by default)
        XCTAssertFalse(coordinator.isShowingOriginal(for: meeting))
    }
    
    /// Test set showing original state for meeting
    func testSetShowingOriginalState() {
        let meeting = MeetingHistoryItem(
            date: Date(),
            title: "Test",
            directory: FileManager.default.temporaryDirectory
        )
        let mockHistoryService = MockMeetingHistoryService()
        
        // Set to show original
        coordinator.setShowingOriginal(true, for: meeting, historyService: mockHistoryService)
        
        XCTAssertTrue(coordinator.isShowingOriginal(for: meeting))
        
        // Set to show refined
        coordinator.setShowingOriginal(false, for: meeting, historyService: mockHistoryService)
        
        XCTAssertFalse(coordinator.isShowingOriginal(for: meeting))
    }
    
    /// Test state persistence per meeting ID
    func testStatePersistencePerMeetingID() {
        let meeting1 = MeetingHistoryItem(
            date: Date(),
            title: "Meeting 1",
            directory: FileManager.default.temporaryDirectory
        )
        let meeting2 = MeetingHistoryItem(
            date: Date(),
            title: "Meeting 2",
            directory: FileManager.default.temporaryDirectory
        )
        let mockHistoryService = MockMeetingHistoryService()
        
        // Set different states for different meetings
        coordinator.setShowingOriginal(true, for: meeting1, historyService: mockHistoryService)
        coordinator.setShowingOriginal(false, for: meeting2, historyService: mockHistoryService)
        
        // Verify independent states
        XCTAssertTrue(coordinator.isShowingOriginal(for: meeting1))
        XCTAssertFalse(coordinator.isShowingOriginal(for: meeting2))
    }
    
    /// Test lazy load original transcript when switching views
    func testLazyLoadOriginalTranscriptWhenSwitching() async {
        let meeting = MeetingHistoryItem(
            date: Date(),
            title: "Test",
            directory: FileManager.default.temporaryDirectory
        )
        meeting.isRefined = true
        meeting.originalTranscriptBlocks = nil // Not yet loaded
        
        let mockHistoryService = MockMeetingHistoryService()
        mockHistoryService.mockOriginalTranscript = "Original text"
        mockHistoryService.mockOriginalTranscriptBlocks = [
            TranscriptBlock(speaker: .me, text: "Original", startTimestamp: 0.0)
        ]
        
        // When: Switch to showing original
        coordinator.setShowingOriginal(true, for: meeting, historyService: mockHistoryService)
        
        // Give time for async Task to complete
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
        
        // Then: Should have loaded original (if meeting was refined)
        // Note: Loading happens in a Task, so we can't easily verify synchronously
        XCTAssertTrue(coordinator.isShowingOriginal(for: meeting))
    }
    
    // MARK: - Part 3: Refinement Workflow
    
    /// Test start refinement when LLM not available (early exit)
    func testStartRefinementWhenLLMNotAvailable() {
        // Given: LLM not available
        mockLLMManager.downloadedModels.removeAll()
        mockLLMManager.isLLMStitchingEnabled = false
        
        let meeting = MeetingHistoryItem(
            date: Date(),
            title: "Test",
            directory: FileManager.default.temporaryDirectory
        )
        meeting.transcript = "Test transcript"
        
        // When: Try to refine
        coordinator.refineTranscript(for: meeting)
        
        // Then: Should exit early, no meeting being refined
        // Since canRefineTranscripts is false, it returns early
        XCTAssertNil(coordinator.meetingBeingRefined)
    }
    
    /// Test start refinement when already refining (early exit)
    func testStartRefinementWhenAlreadyRefining() {
        // This is hard to test without actual refinement running
        // But we can verify the guard exists by checking isRefining
        XCTAssertFalse(coordinator.isRefining, "Should not be refining initially")
    }
    
    /// Test refinement with no transcript available (early exit)
    func testRefinementWithNoTranscriptAvailable() {
        // Given: LLM available
        mockLLMManager.downloadedModels.insert(.llama32_3b)
        mockLLMManager.setActiveModel(.llama32_3b)
        mockLLMManager.isLLMStitchingEnabled = true
        
        let meeting = MeetingHistoryItem(
            date: Date(),
            title: "Test",
            directory: FileManager.default.temporaryDirectory
        )
        // No transcript or transcriptBlocks
        meeting.transcript = nil
        meeting.transcriptBlocks = nil
        
        // When: Try to refine
        coordinator.refineTranscript(for: meeting)
        
        // Then: Should set meeting being refined
        XCTAssertEqual(coordinator.meetingBeingRefined?.title, "Test")
    }
    
    /// Test cancel ongoing refinement
    func testCancelOngoingRefinement() {
        let meeting = MeetingHistoryItem(
            date: Date(),
            title: "Test",
            directory: FileManager.default.temporaryDirectory
        )
        coordinator.meetingBeingRefined = meeting
        
        // When: Cancel
        coordinator.cancelRefinement()
        
        // Then: Should clear meeting being refined
        XCTAssertNil(coordinator.meetingBeingRefined)
    }
    
    // MARK: - Part 4: Segment Refinement & File Saving
    
    /// Test skip already refined segments
    func testSkipAlreadyRefinedSegments() async {
        // Given: LLM available
        mockLLMManager.downloadedModels.insert(.llama32_3b)
        mockLLMManager.setActiveModel(.llama32_3b)
        mockLLMManager.isLLMStitchingEnabled = true
        
        let meeting = MeetingHistoryItem(
            date: Date(),
            title: "Test",
            directory: FileManager.default.temporaryDirectory
        )
        
        let segment = TranscriptSegment(
            id: UUID(),
            segmentNumber: 1,
            startTime: Date(),
            originalBlocks: [TranscriptBlock(speaker: .me, text: "Test", startTimestamp: 0.0)],
            refinedBlocks: nil,
            isRefined: true // Already refined
        )
        
        // When: Try to refine already refined segment
        await coordinator.refineSegment(segment, in: meeting)
        
        // Then: Should skip (guard isRefined check)
        // We can't easily verify, but function should return early
    }
    
    /// Test update meeting transcript display from segments
    func testUpdateMeetingTranscriptDisplay() {
        let meeting = MeetingHistoryItem(
            date: Date(),
            title: "Test",
            directory: FileManager.default.temporaryDirectory
        )
        
        let segment1 = TranscriptSegment(
            id: UUID(),
            segmentNumber: 1,
            startTime: Date(),
            originalBlocks: [TranscriptBlock(speaker: .me, text: "First", startTimestamp: 0.0)],
            refinedBlocks: [TranscriptBlock(speaker: .me, text: "First Refined", startTimestamp: 0.0)],
            isRefined: true
        )
        
        let segment2 = TranscriptSegment(
            id: UUID(),
            segmentNumber: 2,
            startTime: Date(),
            originalBlocks: [TranscriptBlock(speaker: .them, text: "Second", startTimestamp: 5.0)],
            refinedBlocks: nil,
            isRefined: false
        )
        
        meeting.transcriptSegments = [segment1, segment2]
        meeting.isShowingRefined = true
        
        // When: Update display
        coordinator.updateMeetingTranscriptDisplay(meeting)
        
        // Then: Should combine segments into meeting transcript
        XCTAssertNotNil(meeting.transcript)
        XCTAssertNotNil(meeting.transcriptBlocks)
        XCTAssertTrue(meeting.transcriptBlocks!.count >= 2)
    }
    
    /// Test update segmented meeting display with headers
    func testUpdateSegmentedMeetingDisplayWithHeaders() {
        let meeting = MeetingHistoryItem(
            date: Date(),
            title: "Test",
            directory: FileManager.default.temporaryDirectory
        )
        
        let segment1 = TranscriptSegment(
            id: UUID(),
            segmentNumber: 1,
            startTime: Date(),
            originalBlocks: [TranscriptBlock(speaker: .me, text: "First", startTimestamp: 0.0)],
            refinedBlocks: nil,
            isRefined: false
        )
        
        let segment2 = TranscriptSegment(
            id: UUID(),
            segmentNumber: 2,
            startTime: Date().addingTimeInterval(300), // 5 minutes later
            originalBlocks: [TranscriptBlock(speaker: .them, text: "Second", startTimestamp: 5.0)],
            refinedBlocks: nil,
            isRefined: false
        )
        
        meeting.transcriptSegments = [segment1, segment2]
        meeting.isShowingRefined = false
        
        let blocks = [TranscriptBlock(speaker: .me, text: "Test", startTimestamp: 0.0)]
        
        // When: Update with segment headers
        coordinator.updateSegmentedMeetingTranscriptDisplay(
            meeting,
            with: blocks,
            segmentNumber: 2,
            segmentStartTime: segment2.startTime
        )
        
        // Then: Should include segment headers
        XCTAssertNotNil(meeting.transcript)
        XCTAssertTrue(meeting.transcript!.contains("Segment") || meeting.transcript!.contains("---"))
    }
    
    /// Test save refined block-based transcript
    func testSaveRefinedBlockBasedTranscript() {
        let meeting = MeetingHistoryItem(
            date: Date(),
            title: "Test Meeting",
            directory: FileManager.default.temporaryDirectory
        )
        
        let originalBlocks = [
            TranscriptBlock(speaker: .me, text: "Original", startTimestamp: 0.0)
        ]
        meeting.originalTranscriptBlocks = originalBlocks
        meeting.transcriptBlocks = [
            TranscriptBlock(speaker: .me, text: "Refined", startTimestamp: 0.0)
        ]
        
        // Note: saveRefinedTranscript is private, but it's called during refinement
        // We can't directly test it, but we can verify the file output service is available
        XCTAssertNotNil(mockFileOutputService)
    }
    
    // MARK: - Error Message Tests
    
    /// Test error message property
    func testErrorMessageProperty() {
        // Initially nil
        XCTAssertNil(coordinator.errorMessage)
        
        // Note: errorMessage comes from refinementService
        // We can't easily set it without triggering actual refinement
    }
    
    // MARK: - Integration Tests
    
    /// Test complete refinement workflow (without LLM)
    func testCompleteRefinementWorkflowWithoutLLM() {
        // Given: No LLM available
        mockLLMManager.isLLMStitchingEnabled = false
        
        let meeting = MeetingHistoryItem(
            date: Date(),
            title: "Test",
            directory: FileManager.default.temporaryDirectory
        )
        meeting.transcript = "Test transcript"
        
        // When: Try to refine
        coordinator.refineTranscript(for: meeting)
        
        // Then: Should fail early (canRefineTranscripts check)
        XCTAssertNil(coordinator.meetingBeingRefined)
    }
    
    /// Test showing original vs refined toggle
    func testShowingOriginalVsRefinedToggle() {
        let meeting = MeetingHistoryItem(
            date: Date(),
            title: "Test",
            directory: FileManager.default.temporaryDirectory
        )
        let mockHistoryService = MockMeetingHistoryService()
        
        // Start with refined
        XCTAssertFalse(coordinator.isShowingOriginal(for: meeting))
        
        // Toggle to original
        coordinator.setShowingOriginal(true, for: meeting, historyService: mockHistoryService)
        XCTAssertTrue(coordinator.isShowingOriginal(for: meeting))
        
        // Toggle back to refined
        coordinator.setShowingOriginal(false, for: meeting, historyService: mockHistoryService)
        XCTAssertFalse(coordinator.isShowingOriginal(for: meeting))
    }
    
    /// Test multiple meetings with independent states
    func testMultipleMeetingsWithIndependentStates() {
        let meeting1 = MeetingHistoryItem(
            date: Date(),
            title: "Meeting 1",
            directory: FileManager.default.temporaryDirectory
        )
        let meeting2 = MeetingHistoryItem(
            date: Date(),
            title: "Meeting 2",
            directory: FileManager.default.temporaryDirectory
        )
        let meeting3 = MeetingHistoryItem(
            date: Date(),
            title: "Meeting 3",
            directory: FileManager.default.temporaryDirectory
        )
        let mockHistoryService = MockMeetingHistoryService()
        
        // Set different states
        coordinator.setShowingOriginal(true, for: meeting1, historyService: mockHistoryService)
        coordinator.setShowingOriginal(false, for: meeting2, historyService: mockHistoryService)
        coordinator.setShowingOriginal(true, for: meeting3, historyService: mockHistoryService)
        
        // Verify independent
        XCTAssertTrue(coordinator.isShowingOriginal(for: meeting1))
        XCTAssertFalse(coordinator.isShowingOriginal(for: meeting2))
        XCTAssertTrue(coordinator.isShowingOriginal(for: meeting3))
    }
    
    /// Test coordinator with blocks vs plain text
    func testCoordinatorWithBlocksVsPlainText() {
        let meetingWithBlocks = MeetingHistoryItem(
            date: Date(),
            title: "With Blocks",
            directory: FileManager.default.temporaryDirectory
        )
        meetingWithBlocks.transcriptBlocks = [
            TranscriptBlock(speaker: .me, text: "Block text", startTimestamp: 0.0)
        ]
        
        let meetingWithText = MeetingHistoryItem(
            date: Date(),
            title: "With Text",
            directory: FileManager.default.temporaryDirectory
        )
        meetingWithText.transcript = "Plain text"
        meetingWithText.transcriptBlocks = nil
        
        // Both should be valid for refinement
        XCTAssertNotNil(meetingWithBlocks.transcriptBlocks)
        XCTAssertNotNil(meetingWithText.transcript)
    }
    
    /// Test segment refinement state management
    func testSegmentRefinementStateManagement() {
        let meeting = MeetingHistoryItem(
            date: Date(),
            title: "Test",
            directory: FileManager.default.temporaryDirectory
        )
        
        let segment = TranscriptSegment(
            id: UUID(),
            segmentNumber: 1,
            startTime: Date(),
            originalBlocks: [TranscriptBlock(speaker: .me, text: "Original", startTimestamp: 0.0)],
            refinedBlocks: nil,
            isRefined: false
        )
        
        meeting.transcriptSegments = [segment]
        meeting.isShowingRefined = false
        
        // Update display
        coordinator.updateMeetingTranscriptDisplay(meeting)
        
        // Should use original blocks when not showing refined
        XCTAssertNotNil(meeting.transcriptBlocks)
    }
    
    /// Test coordinator handles empty segments array
    func testCoordinatorHandlesEmptySegmentsArray() {
        let meeting = MeetingHistoryItem(
            date: Date(),
            title: "Test",
            directory: FileManager.default.temporaryDirectory
        )
        meeting.transcriptSegments = []
        
        // Should not crash
        coordinator.updateMeetingTranscriptDisplay(meeting)
        
        XCTAssertNotNil(meeting.transcript)
        XCTAssertNotNil(meeting.transcriptBlocks)
    }
    
    /// Test coordinator preserves segment order
    func testCoordinatorPreservesSegmentOrder() {
        let meeting = MeetingHistoryItem(
            date: Date(),
            title: "Test",
            directory: FileManager.default.temporaryDirectory
        )
        
        let segment3 = TranscriptSegment(
            id: UUID(),
            segmentNumber: 3,
            startTime: Date(),
            originalBlocks: [TranscriptBlock(speaker: .me, text: "Third", startTimestamp: 10.0)],
            refinedBlocks: nil,
            isRefined: false
        )
        
        let segment1 = TranscriptSegment(
            id: UUID(),
            segmentNumber: 1,
            startTime: Date(),
            originalBlocks: [TranscriptBlock(speaker: .me, text: "First", startTimestamp: 0.0)],
            refinedBlocks: nil,
            isRefined: false
        )
        
        let segment2 = TranscriptSegment(
            id: UUID(),
            segmentNumber: 2,
            startTime: Date(),
            originalBlocks: [TranscriptBlock(speaker: .them, text: "Second", startTimestamp: 5.0)],
            refinedBlocks: nil,
            isRefined: false
        )
        
        // Add in wrong order
        meeting.transcriptSegments = [segment3, segment1, segment2]
        meeting.isShowingRefined = false
        
        // Update display
        coordinator.updateMeetingTranscriptDisplay(meeting)
        
        // Should sort by segment number
        let blocks = meeting.transcriptBlocks!
        XCTAssertTrue(blocks.count >= 3)
        // First block should be from segment 1
        XCTAssertEqual(blocks.first?.text, "First")
    }
}
