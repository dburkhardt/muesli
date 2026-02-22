@testable import Muesli
import XCTest

@MainActor
final class AINotesCoordinatorTests: XCTestCase {
    private final class StubSummaryService: AINotesSummaryGenerating {
        var callCount = 0
        var output = "Stub summary"
        var delayNanos: UInt64 = 0
        
        func summarize(transcript: String, userPrompt: String) async throws -> String {
            if delayNanos > 0 {
                try await Task.sleep(nanoseconds: delayNanos)
            }
            callCount += 1
            return output
        }
    }
    
    func testGenerateSummary_WritesFileAndUpdatesMeeting() async throws {
        let llmManager = LLMManager(skipHubAccess: true)
        let refinementCoordinator = RefinementCoordinator(llmManager: llmManager)
        let summaryService = StubSummaryService()
        let coordinator = AINotesCoordinator(
            llmManager: llmManager,
            refinementCoordinator: refinementCoordinator,
            summaryService: summaryService
        )
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let meeting = MeetingHistoryItem(
            title: "AI Notes Test",
            date: Date(),
            directory: tempDir,
            transcript: "Transcript content",
            hasAudio: false,
            hasMicrophone: false
        )
        
        coordinator.generateSummary(for: meeting, prompt: "Prompt", force: false)
        try await waitForCompletion(coordinator: coordinator, meeting: meeting)
        
        XCTAssertEqual(summaryService.callCount, 1)
        XCTAssertEqual(meeting.aiSummary, "Stub summary")
        XCTAssertTrue(meeting.hasAISummary)
        XCTAssertEqual(meeting.contentViewMode, .aiSummary)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("ai_summary.md").path)
        )
    }
    
    func testGenerateSummary_SuppressesDuplicateSourceFingerprint() async throws {
        let llmManager = LLMManager(skipHubAccess: true)
        let refinementCoordinator = RefinementCoordinator(llmManager: llmManager)
        let summaryService = StubSummaryService()
        let coordinator = AINotesCoordinator(
            llmManager: llmManager,
            refinementCoordinator: refinementCoordinator,
            summaryService: summaryService
        )
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let meeting = MeetingHistoryItem(
            title: "AI Notes Test",
            date: Date(),
            directory: tempDir,
            transcript: "Transcript content",
            hasAudio: false,
            hasMicrophone: false
        )
        
        coordinator.generateSummary(for: meeting, prompt: "Prompt", force: false)
        try await waitForCompletion(coordinator: coordinator, meeting: meeting)
        
        coordinator.generateSummary(for: meeting, prompt: "Prompt", force: false)
        // Bypass duplicate-trigger cooldown so manual-edit policy executes.
        try await Task.sleep(for: .milliseconds(900))
        
        XCTAssertEqual(summaryService.callCount, 1)
    }
    
    func testGenerateSummary_PreservesManualEditsUnlessForced() async throws {
        let llmManager = LLMManager(skipHubAccess: true)
        let refinementCoordinator = RefinementCoordinator(llmManager: llmManager)
        let summaryService = StubSummaryService()
        let coordinator = AINotesCoordinator(
            llmManager: llmManager,
            refinementCoordinator: refinementCoordinator,
            summaryService: summaryService
        )
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let meeting = MeetingHistoryItem(
            title: "AI Notes Test",
            date: Date(),
            directory: tempDir,
            transcript: "Transcript content",
            hasAudio: false,
            hasMicrophone: false
        )
        
        var warningCount = 0
        coordinator.onWarning = { _, _, _ in warningCount += 1 }
        
        coordinator.generateSummary(for: meeting, prompt: "Prompt", force: false)
        try await waitForCompletion(coordinator: coordinator, meeting: meeting)
        
        let summaryURL = tempDir.appendingPathComponent("ai_summary.md")
        try "manually edited notes".write(to: summaryURL, atomically: true, encoding: .utf8)
        
        // Bypass duplicate-trigger cooldown so manual-edit policy executes.
        try await Task.sleep(for: .milliseconds(900))
        coordinator.generateSummary(for: meeting, prompt: "Prompt", force: false)
        try await Task.sleep(for: .milliseconds(100))
        
        XCTAssertEqual(summaryService.callCount, 1)
        XCTAssertEqual(warningCount, 1)
        
        coordinator.generateSummary(for: meeting, prompt: "Prompt", force: true)
        try await waitForCompletion(coordinator: coordinator, meeting: meeting)
        XCTAssertEqual(summaryService.callCount, 2)
    }
    
    func testGenerateSummary_EmptyTranscriptShowsWarning() async throws {
        let llmManager = LLMManager(skipHubAccess: true)
        let refinementCoordinator = RefinementCoordinator(llmManager: llmManager)
        let summaryService = StubSummaryService()
        let coordinator = AINotesCoordinator(
            llmManager: llmManager,
            refinementCoordinator: refinementCoordinator,
            summaryService: summaryService
        )
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let meeting = MeetingHistoryItem(
            title: "Empty Transcript",
            date: Date(),
            directory: tempDir,
            transcript: "   ",
            hasAudio: false,
            hasMicrophone: false
        )
        
        var warningTitle: String?
        coordinator.onWarning = { title, _, _ in warningTitle = title }
        
        coordinator.generateSummary(for: meeting, prompt: "Prompt", force: false)
        
        XCTAssertEqual(summaryService.callCount, 0)
        XCTAssertEqual(warningTitle, "AI notes unavailable")
    }
    
    func testSetContentMode_RequiresSummaryForAISummaryMode() {
        let llmManager = LLMManager(skipHubAccess: true)
        let refinementCoordinator = RefinementCoordinator(llmManager: llmManager)
        let coordinator = AINotesCoordinator(
            llmManager: llmManager,
            refinementCoordinator: refinementCoordinator,
            summaryService: StubSummaryService()
        )
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let meeting = MeetingHistoryItem(
            title: "Mode Switch",
            date: Date(),
            directory: tempDir,
            transcript: "Transcript content",
            hasAudio: false,
            hasMicrophone: false
        )
        
        coordinator.setContentMode(.aiSummary, for: meeting)
        XCTAssertEqual(meeting.contentViewMode, .transcript)
        
        meeting.hasAISummary = true
        coordinator.setContentMode(.aiSummary, for: meeting)
        XCTAssertEqual(meeting.contentViewMode, .aiSummary)
    }
    
    func testCancelSummary_ClearsLoadingAndStopsTask() async throws {
        let llmManager = LLMManager(skipHubAccess: true)
        let refinementCoordinator = RefinementCoordinator(llmManager: llmManager)
        let summaryService = StubSummaryService()
        summaryService.delayNanos = 1_000_000_000
        let coordinator = AINotesCoordinator(
            llmManager: llmManager,
            refinementCoordinator: refinementCoordinator,
            summaryService: summaryService
        )
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let meeting = MeetingHistoryItem(
            title: "Cancel Summary",
            date: Date(),
            directory: tempDir,
            transcript: "Transcript content",
            hasAudio: false,
            hasMicrophone: false
        )
        
        coordinator.generateSummary(for: meeting, prompt: "Prompt", force: false)
        try await Task.sleep(nanoseconds: 50_000_000)
        coordinator.cancelSummary(for: meeting)
        
        XCTAssertFalse(coordinator.isGeneratingSummary(for: meeting))
        XCTAssertFalse(meeting.isLoadingAISummary)
    }
    
    private func waitForCompletion(
        coordinator: AINotesCoordinator,
        meeting: MeetingHistoryItem
    ) async throws {
        let timeoutNanos: UInt64 = 2_000_000_000
        let start = DispatchTime.now().uptimeNanoseconds
        while coordinator.isGeneratingSummary(for: meeting) {
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNanos {
                XCTFail("Timed out waiting for summary generation")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
