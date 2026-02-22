import Foundation
@testable import Muesli
import XCTest

/// Tests for ExportService
@MainActor
final class ExportServiceTests: XCTestCase {
    // MARK: - Test Properties
    
    var tempDirectory: URL!
    var exportService: ExportService!
    
    override func setUp() async throws {
        try await super.setUp()
        
        // Create temporary directory for test exports
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuesliExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        
        // Create export service with custom export directory
        exportService = ExportService()
        exportService.setExportDirectory(tempDirectory)
    }
    
    override func tearDown() async throws {
        // Clean up temp directory
        try? FileManager.default.removeItem(at: tempDirectory)
        exportService = nil
        tempDirectory = nil
        
        try await super.tearDown()
    }
    
    // MARK: - Test Helpers
    
    /// Create a test meeting with transcript
    private func createTestMeeting(title: String = "Test Meeting", hasAudio: Bool = true) throws -> MeetingHistoryItem {
        // Create meeting directory
        let meetingDir = tempDirectory.appendingPathComponent("recordings/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        
        // Create transcript file
        let transcriptURL = meetingDir.appendingPathComponent("transcript.md")
        let transcript = """
        # \(title)
        2026-01-18 10:30
        
        ## Transcript
        
        **Me** _[0:15]_
        
        Hello everyone, welcome to the meeting.
        
        **Them** _[0:25]_
        
        Thanks for having us!
        """
        try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
        
        // Optionally create audio files
        if hasAudio {
            let audioURL = meetingDir.appendingPathComponent("audio.caf")
            let micURL = meetingDir.appendingPathComponent("microphone.caf")
            try Data().write(to: audioURL)
            try Data().write(to: micURL)
        }
        
        return MeetingHistoryItem(
            id: UUID(),
            title: title,
            date: Date(),
            directory: meetingDir,
            hasAudio: hasAudio,
            hasMicrophone: hasAudio
        )
    }
    
    // MARK: - Directory Creation Tests
    
    func testExportDirectoryCreation() async throws {
        let meeting = try createTestMeeting()
        
        try await exportService.exportMeeting(meeting)
        
        // Verify export directory exists
        let exportDir = exportService.exportDirectory
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportDir.path))
        
        // Verify meetings subdirectory exists
        let meetingsDir = exportDir.appendingPathComponent("meetings")
        XCTAssertTrue(FileManager.default.fileExists(atPath: meetingsDir.path))
        
        // Verify version marker exists
        let markerPath = exportDir.appendingPathComponent(".muesli-export")
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerPath.path))
    }
    
    // MARK: - Meeting Export Tests
    
    func testExportSingleMeeting() async throws {
        let meeting = try createTestMeeting(title: "Team Standup")
        
        try await exportService.exportMeeting(meeting)
        
        // Verify meeting export directory exists
        let meetingExportDir = exportService.exportDirectory
            .appendingPathComponent("meetings")
            .appendingPathComponent(meeting.directory.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: meetingExportDir.path))
        
        // Verify transcript was copied
        let transcriptURL = meetingExportDir.appendingPathComponent("transcript.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcriptURL.path))
        let content = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(content.contains("Team Standup"))
        
        // Verify metadata.json exists and is valid JSON
        let metadataURL = meetingExportDir.appendingPathComponent("metadata.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))
        
        let metadataData = try Data(contentsOf: metadataURL)
        let metadata = try JSONDecoder().decode(MeetingMetadata.self, from: metadataData)
        XCTAssertEqual(metadata.title, "Team Standup")
        XCTAssertTrue(metadata.hasAudio)
    }
    
    func testExportMeetingWithoutAudio() async throws {
        let meeting = try createTestMeeting(title: "Notes Only", hasAudio: false)
        
        try await exportService.exportMeeting(meeting)
        
        // Verify metadata reflects no audio
        let meetingExportDir = exportService.exportDirectory
            .appendingPathComponent("meetings")
            .appendingPathComponent(meeting.directory.lastPathComponent)
        let metadataURL = meetingExportDir.appendingPathComponent("metadata.json")
        
        let metadataData = try Data(contentsOf: metadataURL)
        let metadata = try JSONDecoder().decode(MeetingMetadata.self, from: metadataData)
        XCTAssertFalse(metadata.hasAudio)
        XCTAssertFalse(metadata.hasMicrophone)
        XCTAssertNil(metadata.files.audio)
        XCTAssertNil(metadata.files.microphone)
    }
    
    func testReexportMeeting() async throws {
        let meeting = try createTestMeeting(title: "Original Title")
        
        // Export first time
        try await exportService.exportMeeting(meeting)
        
        // Update meeting title
        let updatedMeeting = MeetingHistoryItem(
            id: meeting.id,
            title: "Updated Title",
            date: meeting.date,
            directory: meeting.directory,
            hasAudio: meeting.hasAudio,
            hasMicrophone: meeting.hasMicrophone
        )
        
        // Re-export
        try await exportService.exportMeeting(updatedMeeting)
        
        // Verify updated title in metadata
        let meetingExportDir = exportService.exportDirectory
            .appendingPathComponent("meetings")
            .appendingPathComponent(meeting.directory.lastPathComponent)
        let metadataURL = meetingExportDir.appendingPathComponent("metadata.json")
        
        let metadataData = try Data(contentsOf: metadataURL)
        let metadata = try JSONDecoder().decode(MeetingMetadata.self, from: metadataData)
        XCTAssertEqual(metadata.title, "Updated Title")
    }
    
    // MARK: - Manifest Tests
    
    func testGenerateManifest() async throws {
        let meeting1 = try createTestMeeting(title: "Meeting 1")
        let meeting2 = try createTestMeeting(title: "Meeting 2")
        let meetings = [meeting1, meeting2]
        
        try exportService.generateManifest(for: meetings)
        
        // Verify manifest exists
        let manifestURL = exportService.exportDirectory.appendingPathComponent("manifest.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        
        // Verify manifest content
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(ExportManifest.self, from: manifestData)
        XCTAssertEqual(manifest.version, "1.0")
        XCTAssertEqual(manifest.totalMeetings, 2)
        XCTAssertEqual(manifest.meetings.count, 2)
        XCTAssertEqual(manifest.meetings[0].title, "Meeting 1")
        XCTAssertEqual(manifest.meetings[1].title, "Meeting 2")
    }
    
    func testExportAllMeetings() async throws {
        let meeting1 = try createTestMeeting(title: "Meeting 1")
        let meeting2 = try createTestMeeting(title: "Meeting 2")
        let meetings = [meeting1, meeting2]
        
        let count = try await exportService.exportAllMeetings(meetings)
        
        XCTAssertEqual(count, 2)
        
        // Verify manifest was generated
        let manifestURL = exportService.exportDirectory.appendingPathComponent("manifest.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(ExportManifest.self, from: manifestData)
        XCTAssertEqual(manifest.totalMeetings, 2)
    }
    
    func testExportAllMeetingsPartialFailure() async throws {
        let validMeeting = try createTestMeeting(title: "Valid Meeting")
        
        // Create invalid meeting (no transcript file)
        let invalidMeetingDir = tempDirectory.appendingPathComponent("recordings/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: invalidMeetingDir, withIntermediateDirectories: true)
        let invalidMeeting = MeetingHistoryItem(
            id: UUID(),
            title: "Invalid Meeting",
            date: Date(),
            directory: invalidMeetingDir,
            hasAudio: false,
            hasMicrophone: false
        )
        
        let meetings = [validMeeting, invalidMeeting]
        
        // Should export valid meeting and skip invalid one
        let count = try await exportService.exportAllMeetings(meetings)
        
        // At least the valid meeting should be exported
        XCTAssertGreaterThanOrEqual(count, 1)
    }
    
    // MARK: - Configuration Tests
    
    func testSetCustomExportDirectory() {
        let customDir = tempDirectory.appendingPathComponent("custom-export")
        
        exportService.setExportDirectory(customDir)
        
        XCTAssertEqual(exportService.exportDirectory, customDir)
    }
    
    func testResetToDefaultExportDirectory() {
        let customDir = tempDirectory.appendingPathComponent("custom-export")
        exportService.setExportDirectory(customDir)
        
        exportService.resetToDefaultExportDirectory()
        
        // Should not equal custom dir anymore
        XCTAssertNotEqual(exportService.exportDirectory, customDir)
    }
    
    // MARK: - Version Marker Tests
    
    func testVersionMarkerCreation() throws {
        try exportService.createVersionMarker()
        
        let markerPath = exportService.exportDirectory.appendingPathComponent(".muesli-export")
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerPath.path))
        
        let content = try String(contentsOf: markerPath, encoding: .utf8)
        XCTAssertTrue(content.contains("version=1.0"))
        XCTAssertTrue(content.contains("format=markdown+json"))
    }
    
    // MARK: - Edge Case Tests
    
    func testExportMeetingWithEmptyTranscript() async throws {
        let meeting = try createTestMeeting(title: "Empty Meeting")
        
        // Overwrite transcript with empty content
        let transcriptURL = meeting.directory.appendingPathComponent("transcript.md")
        try """
            # Empty Meeting
            2026-01-18 10:30
            
            ## Transcript
            
            
            """.write(to: transcriptURL, atomically: true, encoding: .utf8)
        
        // Should still export successfully
        try await exportService.exportMeeting(meeting)
        
        let meetingExportDir = exportService.exportDirectory
            .appendingPathComponent("meetings")
            .appendingPathComponent(meeting.directory.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: meetingExportDir.path))
    }
    
    func testExportMeetingWithSpecialCharactersInTitle() async throws {
        let specialTitle = "Meeting: Q1/2026 [Review] & Planning"
        let meeting = try createTestMeeting(title: specialTitle)
        
        try await exportService.exportMeeting(meeting)
        
        let meetingExportDir = exportService.exportDirectory
            .appendingPathComponent("meetings")
            .appendingPathComponent(meeting.directory.lastPathComponent)
        let metadataURL = meetingExportDir.appendingPathComponent("metadata.json")
        
        let metadataData = try Data(contentsOf: metadataURL)
        let metadata = try JSONDecoder().decode(MeetingMetadata.self, from: metadataData)
        XCTAssertEqual(metadata.title, specialTitle)
    }
    
    func testExportMeetingWithRefinedTranscript() async throws {
        let meeting = try createTestMeeting(title: "Refined Meeting")
        meeting.isRefined = true
        
        try await exportService.exportMeeting(meeting)
        
        let meetingExportDir = exportService.exportDirectory
            .appendingPathComponent("meetings")
            .appendingPathComponent(meeting.directory.lastPathComponent)
        let metadataURL = meetingExportDir.appendingPathComponent("metadata.json")
        
        let metadataData = try Data(contentsOf: metadataURL)
        let metadata = try JSONDecoder().decode(MeetingMetadata.self, from: metadataData)
        XCTAssertTrue(metadata.isRefined)
    }
    
    func testExportMeetingWithMultipleSegments() async throws {
        let meeting = try createTestMeeting(title: "Multi-segment Meeting")
        
        // Add transcript segments
        let segment1 = TranscriptSegment(
            id: UUID(),
            segmentNumber: 1,
            originalBlocks: [],
            isRefined: false,
            startTime: Date()
        )
        let segment2 = TranscriptSegment(
            id: UUID(),
            segmentNumber: 2,
            originalBlocks: [],
            isRefined: false,
            startTime: Date().addingTimeInterval(600)
        )
        meeting.transcriptSegments = [segment1, segment2]
        meeting.segmentCount = 2
        
        try await exportService.exportMeeting(meeting)
        
        let meetingExportDir = exportService.exportDirectory
            .appendingPathComponent("meetings")
            .appendingPathComponent(meeting.directory.lastPathComponent)
        let metadataURL = meetingExportDir.appendingPathComponent("metadata.json")
        
        let metadataData = try Data(contentsOf: metadataURL)
        let metadata = try JSONDecoder().decode(MeetingMetadata.self, from: metadataData)
        XCTAssertEqual(metadata.segmentCount, 2)
        XCTAssertEqual(metadata.segments.count, 2)
        XCTAssertEqual(metadata.segments[0].segmentNumber, 1)
        XCTAssertEqual(metadata.segments[1].segmentNumber, 2)
    }
    
    func testExportMeetingWithDurationAndWordCount() async throws {
        let meeting = try createTestMeeting(title: "Detailed Meeting")
        
        // Create a new meeting item with duration and word count
        let detailedMeeting = MeetingHistoryItem(
            id: meeting.id,
            title: meeting.title,
            date: meeting.date,
            directory: meeting.directory,
            hasAudio: meeting.hasAudio,
            hasMicrophone: meeting.hasMicrophone,
            duration: 1847.5,
            wordCount: 2450
        )
        
        try await exportService.exportMeeting(detailedMeeting)
        
        let meetingExportDir = exportService.exportDirectory
            .appendingPathComponent("meetings")
            .appendingPathComponent(meeting.directory.lastPathComponent)
        let metadataURL = meetingExportDir.appendingPathComponent("metadata.json")
        
        let metadataData = try Data(contentsOf: metadataURL)
        let metadata = try JSONDecoder().decode(MeetingMetadata.self, from: metadataData)
        XCTAssertEqual(metadata.duration, 1847.5)
        XCTAssertEqual(metadata.wordCount, 2450)
    }
    
    func testManifestPreservesMeetingOrder() async throws {
        let meeting1 = try createTestMeeting(title: "First Meeting")
        let meeting2 = try createTestMeeting(title: "Second Meeting")
        let meeting3 = try createTestMeeting(title: "Third Meeting")
        let meetings = [meeting1, meeting2, meeting3]
        
        try exportService.generateManifest(for: meetings)
        
        let manifestURL = exportService.exportDirectory.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(ExportManifest.self, from: manifestData)
        
        XCTAssertEqual(manifest.meetings[0].title, "First Meeting")
        XCTAssertEqual(manifest.meetings[1].title, "Second Meeting")
        XCTAssertEqual(manifest.meetings[2].title, "Third Meeting")
    }
    
    func testExportEmptyMeetingsArray() async throws {
        let meetings: [MeetingHistoryItem] = []
        
        let count = try await exportService.exportAllMeetings(meetings)
        
        XCTAssertEqual(count, 0)
        
        let manifestURL = exportService.exportDirectory.appendingPathComponent("manifest.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(ExportManifest.self, from: manifestData)
        XCTAssertEqual(manifest.totalMeetings, 0)
        XCTAssertTrue(manifest.meetings.isEmpty)
    }
    
    func testManifestIncludesTimestamp() async throws {
        let meeting = try createTestMeeting()
        try exportService.generateManifest(for: [meeting])
        
        let manifestURL = exportService.exportDirectory.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(ExportManifest.self, from: manifestData)
        
        // Verify timestamp is in ISO 8601 format
        XCTAssertFalse(manifest.generatedAt.isEmpty)
        XCTAssertTrue(manifest.generatedAt.contains("T"))
        XCTAssertTrue(manifest.generatedAt.contains("Z") || manifest.generatedAt.contains("+"))
    }
    
    func testExportDirectoryPersistence() {
        let customDir = tempDirectory.appendingPathComponent("custom-persistent")
        
        // Set custom directory
        exportService.setExportDirectory(customDir)
        
        // Verify it's stored in UserDefaults
        let savedPath = UserDefaults.standard.string(forKey: AppStorageKeys.exportDirectory)
        XCTAssertEqual(savedPath, customDir.path)
        
        // Reset
        exportService.resetToDefaultExportDirectory()
        let resetPath = UserDefaults.standard.string(forKey: AppStorageKeys.exportDirectory)
        XCTAssertNil(resetPath)
    }
    
    func testMetadataUsesRelativePaths() async throws {
        let meeting = try createTestMeeting(title: "Path Test")
        
        try await exportService.exportMeeting(meeting)
        
        let meetingExportDir = exportService.exportDirectory
            .appendingPathComponent("meetings")
            .appendingPathComponent(meeting.directory.lastPathComponent)
        let metadataURL = meetingExportDir.appendingPathComponent("metadata.json")
        
        let metadataData = try Data(contentsOf: metadataURL)
        let metadata = try JSONDecoder().decode(MeetingMetadata.self, from: metadataData)
        
        // Verify audio paths are relative
        XCTAssertTrue(metadata.files.audio?.starts(with: "../../Recordings/") == true)
        XCTAssertTrue(metadata.files.microphone?.starts(with: "../../Recordings/") == true)
        
        // Verify transcript path is relative
        XCTAssertEqual(metadata.files.transcript, "transcript.md")
    }
    
    func testMeetingsSubdirectoryCreation() async throws {
        let meeting = try createTestMeeting()
        
        // Remove meetings directory if it exists
        let meetingsDir = exportService.exportDirectory.appendingPathComponent("meetings")
        try? FileManager.default.removeItem(at: meetingsDir)
        
        try await exportService.exportMeeting(meeting)
        
        // Verify meetings directory was created
        XCTAssertTrue(FileManager.default.fileExists(atPath: meetingsDir.path))
    }
    
    func testManifestContainsVersion() async throws {
        let meeting = try createTestMeeting()
        try exportService.generateManifest(for: [meeting])
        
        let manifestURL = exportService.exportDirectory.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(ExportManifest.self, from: manifestData)
        
        XCTAssertEqual(manifest.version, "1.0")
    }
}

// MARK: - PreferencesManager Export Tests

@MainActor
final class PreferencesManagerExportTests: XCTestCase {
    override func tearDown() {
        // Clean up UserDefaults
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.exportEnabled)
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.exportDirectory)
        super.tearDown()
    }
    
    func testExportEnabledDefaultsToTrue() {
        // Clear any existing preference
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.exportEnabled)
        
        let prefs = PreferencesManager()
        
        XCTAssertTrue(prefs.exportEnabled)
    }
    
    func testSetExportEnabled() {
        let prefs = PreferencesManager()
        
        prefs.exportEnabled = false
        XCTAssertFalse(prefs.exportEnabled)
        
        prefs.exportEnabled = true
        XCTAssertTrue(prefs.exportEnabled)
    }
    
    func testExportDirectoryDefaultsToApplicationSupport() {
        // Clear any existing preference
        UserDefaults.standard.removeObject(forKey: AppStorageKeys.exportDirectory)
        
        let prefs = PreferencesManager()
        
        XCTAssertEqual(prefs.exportDirectory, PreferencesManager.defaultExportDirectory)
        XCTAssertTrue(prefs.exportDirectory.path.contains("Application Support/Muesli/Exports"))
    }
    
    func testSetCustomExportDirectory() {
        let prefs = PreferencesManager()
        let customDir = FileManager.default.temporaryDirectory.appendingPathComponent("custom-exports")
        
        prefs.exportDirectory = customDir
        
        XCTAssertEqual(prefs.exportDirectory, customDir)
        
        // Verify it persists
        let savedPath = UserDefaults.standard.string(forKey: AppStorageKeys.exportDirectory)
        XCTAssertEqual(savedPath, customDir.path)
    }
    
    func testResetExportDirectory() {
        let prefs = PreferencesManager()
        let customDir = FileManager.default.temporaryDirectory.appendingPathComponent("custom-exports")
        
        prefs.exportDirectory = customDir
        prefs.resetExportDirectory()
        
        XCTAssertEqual(prefs.exportDirectory, PreferencesManager.defaultExportDirectory)
        
        // Verify UserDefaults is cleared
        let savedPath = UserDefaults.standard.string(forKey: AppStorageKeys.exportDirectory)
        XCTAssertNil(savedPath)
    }
}

// MARK: - Test Data Models

/// Test-accessible version of ExportManifest
private struct ExportManifest: Codable {
    let version: String
    let generatedAt: String
    let totalMeetings: Int
    let meetings: [MeetingEntry]
    
    struct MeetingEntry: Codable {
        let id: String
        let title: String
        let date: String
        let directory: String
        let hasAudio: Bool
        let hasMicrophone: Bool
        let duration: TimeInterval?
        let wordCount: Int?
        let isRefined: Bool
        let segmentCount: Int
    }
}

/// Test-accessible version of MeetingMetadata
private struct MeetingMetadata: Codable {
    let id: String
    let title: String
    let date: String
    let duration: TimeInterval?
    let wordCount: Int?
    let hasAudio: Bool
    let hasMicrophone: Bool
    let isRefined: Bool
    let segmentCount: Int
    let segments: [SegmentInfo]
    let files: FileReferences
    
    struct SegmentInfo: Codable {
        let segmentNumber: Int
        let startTime: String
        let isRefined: Bool
    }
    
    struct FileReferences: Codable {
        let transcript: String
        let audio: String?
        let microphone: String?
    }
}
