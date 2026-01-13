import Foundation
@testable import Muesli

/// Mock implementation of MeetingHistoryService for testing
@MainActor
final class MockMeetingHistoryService: MeetingHistoryServiceProtocol {
    
    // MARK: - Test Data
    
    /// Meetings to return from discoverMeetings()
    var mockMeetings: [MeetingHistoryItem] = []
    
    /// Transcripts keyed by meeting ID
    var mockTranscripts: [UUID: String] = [:]
    
    /// Transcript blocks keyed by meeting ID
    var mockTranscriptBlocks: [UUID: [TranscriptBlock]] = [:]
    
    /// Original transcripts keyed by meeting ID
    var mockOriginalTranscripts: [UUID: String] = [:]
    
    /// Original transcript blocks keyed by meeting ID
    var mockOriginalTranscriptBlocks: [UUID: [TranscriptBlock]] = [:]
    
    // MARK: - Call Tracking
    
    var discoverMeetingsCallCount: Int = 0
    var loadTranscriptCallCount: Int = 0
    var loadTranscriptBlocksCallCount: Int = 0
    var loadOriginalTranscriptCallCount: Int = 0
    var loadOriginalTranscriptBlocksCallCount: Int = 0
    
    // MARK: - MeetingHistoryServiceProtocol
    
    func discoverMeetings() -> [MeetingHistoryItem] {
        discoverMeetingsCallCount += 1
        return mockMeetings
    }
    
    func loadTranscript(for meeting: MeetingHistoryItem) -> String? {
        loadTranscriptCallCount += 1
        return mockTranscripts[meeting.id]
    }
    
    func loadTranscriptBlocks(for meeting: MeetingHistoryItem) -> [TranscriptBlock]? {
        loadTranscriptBlocksCallCount += 1
        return mockTranscriptBlocks[meeting.id]
    }
    
    func loadOriginalTranscriptBlocks(for meeting: MeetingHistoryItem) -> [TranscriptBlock]? {
        loadOriginalTranscriptBlocksCallCount += 1
        return mockOriginalTranscriptBlocks[meeting.id]
    }
    
    func loadOriginalTranscript(for meeting: MeetingHistoryItem) -> String? {
        loadOriginalTranscriptCallCount += 1
        return mockOriginalTranscripts[meeting.id]
    }
    
    // MARK: - Test Helpers
    
    /// Create a mock meeting for testing
    static func createMockMeeting(
        id: UUID = UUID(),
        title: String = "Test Meeting",
        date: Date = Date(),
        hasAudio: Bool = true,
        hasMicrophone: Bool = true,
        duration: TimeInterval? = 3600,
        wordCount: Int? = 500
    ) -> MeetingHistoryItem {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(id.uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        return MeetingHistoryItem(
            id: id,
            title: title,
            date: date,
            directory: tempDir,
            hasAudio: hasAudio,
            hasMicrophone: hasMicrophone,
            duration: duration,
            wordCount: wordCount
        )
    }
    
    /// Add a mock meeting with transcript
    func addMockMeeting(_ meeting: MeetingHistoryItem, transcript: String? = nil, blocks: [TranscriptBlock]? = nil) {
        mockMeetings.append(meeting)
        if let transcript = transcript {
            mockTranscripts[meeting.id] = transcript
        }
        if let blocks = blocks {
            mockTranscriptBlocks[meeting.id] = blocks
        }
    }
    
    /// Reset all state for next test
    func reset() {
        mockMeetings = []
        mockTranscripts = [:]
        mockTranscriptBlocks = [:]
        mockOriginalTranscripts = [:]
        mockOriginalTranscriptBlocks = [:]
        discoverMeetingsCallCount = 0
        loadTranscriptCallCount = 0
        loadTranscriptBlocksCallCount = 0
        loadOriginalTranscriptCallCount = 0
        loadOriginalTranscriptBlocksCallCount = 0
    }
}
