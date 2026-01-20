import AVFoundation
@testable import Muesli
import XCTest

/// Tests for MeetingHistoryService
///
/// Tests use FileManager to create temporary test directories and files
/// to verify meeting discovery, parsing, and transcript loading.
@MainActor
final class MeetingHistoryServiceTests: XCTestCase {
    var service: MeetingHistoryService!
    var testDirectory: URL!
    
    override func setUp() async throws {
        try await super.setUp()
        service = MeetingHistoryService()
        
        // Create temporary test directory
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuesliTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        
        // Set UserDefaults to use test directory
        UserDefaults.standard.set(testDirectory.path, forKey: AppStorageKeys.outputDirectory)
    }
    
    override func tearDown() async throws {
        // Clean up test directory
        try? FileManager.default.removeItem(at: testDirectory)
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.outputDirectory)
        service = nil
        testDirectory = nil
        try await super.tearDown()
    }
    
    // MARK: - Discovery Tests
    
    func testDiscoverMeetings_WithNoMeetings_ReturnsEmptyArray() {
        // Given: Empty directory
        // (setUp already created an empty directory)
        
        // When: Discovering meetings
        let meetings = service.discoverMeetings()
        
        // Then: Should return empty array
        XCTAssertEqual(meetings.count, 0)
    }
    
    func testDiscoverMeetings_WithNonExistentDirectory_ReturnsEmptyArray() {
        // Given: Directory that doesn't exist
        let nonExistentPath = "/tmp/muesli-nonexistent-\(UUID().uuidString)"
        UserDefaults.standard.set(nonExistentPath, forKey: AppStorageKeys.outputDirectory)
        
        // When: Discovering meetings
        let meetings = service.discoverMeetings()
        
        // Then: Should return empty array (not crash)
        XCTAssertEqual(meetings.count, 0)
    }
    
    func testDiscoverMeetings_WithValidMeeting_ReturnsMeeting() throws {
        // Given: Valid meeting directory with transcript
        let meetingDir = testDirectory.appendingPathComponent("2024-01-15_14-30_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        
        let transcriptContent = """
        # Team Standup
        2024-01-15 14:30
        
        ## Transcript
        
        **Me** _[0:05]_
        
        Hello everyone, let's start the standup.
        """
        let transcriptURL = meetingDir.appendingPathComponent("transcript.md")
        try transcriptContent.write(to: transcriptURL, atomically: true, encoding: .utf8)
        
        // When: Discovering meetings
        let meetings = service.discoverMeetings()
        
        // Then: Should find one meeting
        XCTAssertEqual(meetings.count, 1)
        let meeting = try XCTUnwrap(meetings.first)
        XCTAssertEqual(meeting.title, "Team Standup")
        XCTAssertEqual(meeting.directory.standardizedFileURL, meetingDir.standardizedFileURL)
    }
    
    func testDiscoverMeetings_WithMultipleMeetings_SortsNewestFirst() throws {
        // Given: Multiple meeting directories with different dates
        let meeting1Dir = testDirectory.appendingPathComponent("2024-01-15_10-00_\(UUID().uuidString)")
        let meeting2Dir = testDirectory.appendingPathComponent("2024-01-16_11-00_\(UUID().uuidString)")
        let meeting3Dir = testDirectory.appendingPathComponent("2024-01-14_09-00_\(UUID().uuidString)")
        
        for dir in [meeting1Dir, meeting2Dir, meeting3Dir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let content = "# Meeting\n2024-01-15 10:00\n\n## Transcript\n\nTest"
            try content.write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        }
        
        // When: Discovering meetings
        let meetings = service.discoverMeetings()
        
        // Then: Should be sorted newest first
        XCTAssertEqual(meetings.count, 3)
        // Dates should be in descending order
        for i in 0..<(meetings.count - 1) {
            XCTAssertGreaterThanOrEqual(meetings[i].date, meetings[i + 1].date)
        }
    }
    
    func testDiscoverMeetings_SkipsDirectoriesWithoutTranscript() throws {
        // Given: Directory without transcript.md
        let incompleteDir = testDirectory.appendingPathComponent("2024-01-15_14-30_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: incompleteDir, withIntermediateDirectories: true)
        
        // Valid meeting with transcript
        let validDir = testDirectory.appendingPathComponent("2024-01-16_15-30_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: validDir, withIntermediateDirectories: true)
        try "# Valid\n\n## Transcript\n\nContent".write(
            to: validDir.appendingPathComponent("transcript.md"),
            atomically: true,
            encoding: .utf8
        )
        
        // When: Discovering meetings
        let meetings = service.discoverMeetings()
        
        // Then: Should only find valid meeting
        XCTAssertEqual(meetings.count, 1)
    }
    
    func testDiscoverMeetings_SkipsHiddenFiles() throws {
        // Given: Hidden directory (starts with .)
        let hiddenDir = testDirectory.appendingPathComponent(".hidden_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: hiddenDir, withIntermediateDirectories: true)
        try "# Hidden\n\n## Transcript\n\nContent".write(
            to: hiddenDir.appendingPathComponent("transcript.md"),
            atomically: true,
            encoding: .utf8
        )
        
        // When: Discovering meetings
        let meetings = service.discoverMeetings()
        
        // Then: Should not find hidden directory
        XCTAssertEqual(meetings.count, 0)
    }
    
    // MARK: - Parsing Tests
    
    func testParseMeeting_ExtractsTitleFromFirstLine() throws {
        // Given: Meeting with title in first line
        let meetingDir = testDirectory.appendingPathComponent("2024-01-15_14-30_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        
        let content = """
        # Custom Meeting Title
        2024-01-15 14:30
        
        ## Transcript
        
        Content here
        """
        try content.write(to: meetingDir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        
        // When: Discovering meetings
        let meetings = service.discoverMeetings()
        
        // Then: Should extract title
        XCTAssertEqual(meetings.first?.title, "Custom Meeting Title")
    }
    
    func testParseMeeting_DefaultsTitleToMeetingIfNoHeader() throws {
        // Given: Meeting without title header
        let meetingDir = testDirectory.appendingPathComponent("2024-01-15_14-30_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        
        let content = """
        ## Transcript
        
        Content without title header
        """
        try content.write(to: meetingDir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        
        // When: Discovering meetings
        let meetings = service.discoverMeetings()
        
        // Then: Should default to "Meeting"
        XCTAssertEqual(meetings.first?.title, "Meeting")
    }
    
    func testParseMeeting_ParsesDateFromTranscript() throws {
        // Given: Meeting with date in second line
        let meetingDir = testDirectory.appendingPathComponent("2024-01-15_14-30_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        
        let content = """
        # Meeting
        2024-06-20 15:45
        
        ## Transcript
        
        Content
        """
        try content.write(to: meetingDir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        
        // When: Discovering meetings
        let meetings = service.discoverMeetings()
        
        // Then: Should parse date from transcript
        let meeting = try XCTUnwrap(meetings.first)
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: meeting.date)
        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 6)
        XCTAssertEqual(components.day, 20)
        XCTAssertEqual(components.hour, 15)
        XCTAssertEqual(components.minute, 45)
    }
    
    func testParseMeeting_DetectsAudioFiles() throws {
        // Given: Meeting with audio files
        let meetingDir = testDirectory.appendingPathComponent("2024-01-15_14-30_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        try "# Meeting\n\n## Transcript\n\nContent".write(
            to: meetingDir.appendingPathComponent("transcript.md"),
            atomically: true,
            encoding: .utf8
        )
        
        // Create empty audio files
        FileManager.default.createFile(atPath: meetingDir.appendingPathComponent("audio.caf").path, contents: nil)
        FileManager.default.createFile(atPath: meetingDir.appendingPathComponent("microphone.caf").path, contents: nil)
        
        // When: Discovering meetings
        let meetings = service.discoverMeetings()
        
        // Then: Should detect audio files
        let meeting = try XCTUnwrap(meetings.first)
        XCTAssertTrue(meeting.hasAudio)
        XCTAssertTrue(meeting.hasMicrophone)
    }
    
    func testParseMeeting_DetectsRefinedTranscript() throws {
        // Given: Meeting with original transcript
        let meetingDir = testDirectory.appendingPathComponent("2024-01-15_14-30_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        try "# Meeting\n\n## Transcript\n\nRefined".write(
            to: meetingDir.appendingPathComponent("transcript.md"),
            atomically: true,
            encoding: .utf8
        )
        try "# Meeting\n\n## Transcript\n\nOriginal".write(
            to: meetingDir.appendingPathComponent("transcript.original.md"),
            atomically: true,
            encoding: .utf8
        )
        
        // When: Discovering meetings
        let meetings = service.discoverMeetings()
        
        // Then: Should detect refinement
        let meeting = try XCTUnwrap(meetings.first)
        XCTAssertTrue(meeting.isRefined)
    }
    
    func testParseMeeting_ExtractsUUIDFromFolderName() throws {
        // Given: Meeting with UUID in folder name
        let uuid = UUID()
        let meetingDir = testDirectory.appendingPathComponent("2024-01-15_14-30_\(uuid.uuidString)")
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        try "# Meeting\n\n## Transcript\n\nContent".write(
            to: meetingDir.appendingPathComponent("transcript.md"),
            atomically: true,
            encoding: .utf8
        )
        
        // When: Discovering meetings
        let meetings = service.discoverMeetings()
        
        // Then: Should extract UUID
        XCTAssertEqual(meetings.first?.id, uuid)
    }
    
    // MARK: - Transcript Loading Tests
    
    func testLoadTranscript_WithValidTranscript_ReturnsContent() throws {
        // Given: Meeting with transcript
        let meetingDir = testDirectory.appendingPathComponent("2024-01-15_14-30_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        
        let content = """
        # Meeting Title
        2024-01-15 14:30
        
        ## Transcript
        
        **Me** _[0:05]_
        
        This is the transcript content.
        
        **Them** _[0:15]_
        
        More transcript content here.
        """
        try content.write(to: meetingDir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        
        // When: Loading transcript
        let transcript = service.loadTranscript(at: meetingDir)
        
        // Then: Should extract transcript section only
        XCTAssertNotNil(transcript)
        XCTAssertTrue(transcript!.contains("This is the transcript content"))
        XCTAssertTrue(transcript!.contains("More transcript content here"))
        XCTAssertFalse(transcript!.contains("# Meeting Title"))
        XCTAssertFalse(transcript!.contains("## Transcript"))
    }
    
    func testLoadTranscript_WithMissingFile_ReturnsNil() {
        // Given: Directory without transcript
        let emptyDir = testDirectory.appendingPathComponent("empty")
        
        // When: Loading transcript
        let transcript = service.loadTranscript(at: emptyDir)
        
        // Then: Should return nil
        XCTAssertNil(transcript)
    }
    
    func testLoadTranscript_ForMeeting_LoadsCorrectTranscript() throws {
        // Given: Meeting item
        let meetingDir = testDirectory.appendingPathComponent("2024-01-15_14-30_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        
        let content = "# Meeting\n\n## Transcript\n\nTest content"
        try content.write(to: meetingDir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        
        let meetings = service.discoverMeetings()
        let meeting = try XCTUnwrap(meetings.first)
        
        // When: Loading transcript by meeting
        let transcript = service.loadTranscript(for: meeting)
        
        // Then: Should load correct content
        XCTAssertNotNil(transcript)
        XCTAssertTrue(transcript!.contains("Test content"))
    }
    
    // MARK: - Original Transcript Tests
    
    func testLoadOriginalTranscript_WithRefinedMeeting_ReturnsOriginal() throws {
        // Given: Meeting with original transcript
        let meetingDir = testDirectory.appendingPathComponent("2024-01-15_14-30_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        
        let originalContent = "# Meeting\n\n## Transcript\n\nOriginal transcript"
        try originalContent.write(
            to: meetingDir.appendingPathComponent("transcript.original.md"),
            atomically: true,
            encoding: .utf8
        )
        
        // When: Loading original transcript
        let original = service.loadOriginalTranscript(at: meetingDir)
        
        // Then: Should return original content
        XCTAssertNotNil(original)
        XCTAssertTrue(original!.contains("Original transcript"))
    }
    
    func testLoadOriginalTranscript_WithoutRefinement_ReturnsNil() {
        // Given: Meeting without original transcript
        let meetingDir = testDirectory.appendingPathComponent("2024-01-15_14-30_\(UUID().uuidString)")
        
        // When: Loading original transcript
        let original = service.loadOriginalTranscript(at: meetingDir)
        
        // Then: Should return nil
        XCTAssertNil(original)
    }
    
    // MARK: - Transcript Blocks Tests
    
    func testLoadTranscriptBlocks_ParsesBlocksCorrectly() throws {
        // Given: Meeting with structured transcript
        let meetingDir = testDirectory.appendingPathComponent("2024-01-15_14-30_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        
        let content = """
        # Meeting
        
        ## Transcript
        
        **Me** _[0:05]_
        
        First block of text.
        
        **Them** _[0:15]_
        
        Second block of text.
        
        **Me** _[0:30]_
        
        Third block of text.
        """
        try content.write(to: meetingDir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        
        // When: Loading transcript blocks
        let blocks = service.loadTranscriptBlocks(at: meetingDir)
        
        // Then: Should parse blocks correctly
        let unwrappedBlocks = try XCTUnwrap(blocks)
        XCTAssertEqual(unwrappedBlocks.count, 3)
        
        XCTAssertEqual(unwrappedBlocks[0].speaker, .me)
        XCTAssertEqual(unwrappedBlocks[0].startTimestamp, 5)
        XCTAssertTrue(unwrappedBlocks[0].text.contains("First block"))
        
        XCTAssertEqual(unwrappedBlocks[1].speaker, .them)
        XCTAssertEqual(unwrappedBlocks[1].startTimestamp, 15)
        XCTAssertTrue(unwrappedBlocks[1].text.contains("Second block"))
        
        XCTAssertEqual(unwrappedBlocks[2].speaker, .me)
        XCTAssertEqual(unwrappedBlocks[2].startTimestamp, 30)
        XCTAssertTrue(unwrappedBlocks[2].text.contains("Third block"))
    }
    
    func testLoadTranscriptBlocks_UpdatesEndTimestamps() throws {
        // Given: Meeting with multiple blocks
        let meetingDir = testDirectory.appendingPathComponent("2024-01-15_14-30_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        
        let content = """
        # Meeting
        
        ## Transcript
        
        **Me** _[0:05]_
        
        Block 1
        
        **Them** _[0:15]_
        
        Block 2
        """
        try content.write(to: meetingDir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        
        // When: Loading transcript blocks
        let blocks = service.loadTranscriptBlocks(at: meetingDir)
        
        // Then: First block's endTimestamp should match second block's startTimestamp
        let unwrappedBlocks = try XCTUnwrap(blocks)
        XCTAssertEqual(unwrappedBlocks[0].endTimestamp, unwrappedBlocks[1].startTimestamp)
    }
    
    func testLoadTranscriptBlocks_WithInvalidFormat_ReturnsNil() throws {
        // Given: Meeting with invalid transcript format
        let meetingDir = testDirectory.appendingPathComponent("2024-01-15_14-30_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        
        let content = """
        # Meeting
        
        ## Transcript
        
        Plain text without blocks
        """
        try content.write(to: meetingDir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        
        // When: Loading transcript blocks
        let blocks = service.loadTranscriptBlocks(at: meetingDir)
        
        // Then: Should return nil for invalid format
        XCTAssertNil(blocks)
    }
    
    func testLoadOriginalTranscriptBlocks_WithRefinedMeeting_ReturnsOriginalBlocks() throws {
        // Given: Meeting with original transcript blocks
        let meetingDir = testDirectory.appendingPathComponent("2024-01-15_14-30_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        
        let content = """
        # Meeting
        
        ## Transcript
        
        **Me** _[0:05]_
        
        Original block content
        """
        try content.write(
            to: meetingDir.appendingPathComponent("transcript.original.md"),
            atomically: true,
            encoding: .utf8
        )
        
        // When: Loading original blocks
        let blocks = service.loadOriginalTranscriptBlocks(at: meetingDir)
        
        // Then: Should return original blocks
        let unwrappedBlocks = try XCTUnwrap(blocks)
        XCTAssertGreaterThan(unwrappedBlocks.count, 0)
        XCTAssertTrue(unwrappedBlocks[0].text.contains("Original block"))
    }
    
    // MARK: - Edge Cases
    
    func testDiscoverMeetings_WithFilesInsteadOfDirectories_SkipsThem() throws {
        // Given: Regular files instead of directories
        let file1 = testDirectory.appendingPathComponent("file1.txt")
        try "content".write(to: file1, atomically: true, encoding: .utf8)
        
        // When: Discovering meetings
        let meetings = service.discoverMeetings()
        
        // Then: Should skip files
        XCTAssertEqual(meetings.count, 0)
    }
    
    func testLoadTranscript_WithEmptyTranscriptSection_ReturnsNil() throws {
        // Given: Transcript with empty content
        let meetingDir = testDirectory.appendingPathComponent("2024-01-15_14-30_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        
        let content = """
        # Meeting
        
        ## Transcript
        """
        try content.write(to: meetingDir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        
        // When: Loading transcript
        let transcript = service.loadTranscript(at: meetingDir)
        
        // Then: Should return nil for empty content
        XCTAssertNil(transcript)
    }
    
    func testParseMeeting_WithEmptyTitle_DefaultsToMeeting() throws {
        // Given: Transcript with empty title
        let meetingDir = testDirectory.appendingPathComponent("2024-01-15_14-30_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        
        let content = """
        #   
        
        ## Transcript
        
        Content
        """
        try content.write(to: meetingDir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        
        // When: Discovering meetings
        let meetings = service.discoverMeetings()
        
        // Then: Should default to "Meeting"
        XCTAssertEqual(meetings.first?.title, "Meeting")
    }
    
    func testDiscoverMeetings_WithMalformedFolderName_StillDiscoversMeeting() throws {
        // Given: Folder with non-standard name
        let meetingDir = testDirectory.appendingPathComponent("malformed-folder-name")
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        try "# Meeting\n\n## Transcript\n\nContent".write(
            to: meetingDir.appendingPathComponent("transcript.md"),
            atomically: true,
            encoding: .utf8
        )
        
        // When: Discovering meetings
        let meetings = service.discoverMeetings()
        
        // Then: Should still discover meeting (uses fallback date)
        XCTAssertEqual(meetings.count, 1)
        XCTAssertNotNil(meetings.first?.date)
    }
}
