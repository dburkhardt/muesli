import Foundation

/// Represents a historical meeting recording discovered from disk
@Observable
@MainActor
final class MeetingHistoryItem: Identifiable, Hashable {
    let id: UUID
    var title: String
    let date: Date
    let directory: URL
    var transcript: String?
    var transcriptBlocks: [TranscriptBlock]?  // Block-based transcript (if available)
    
    // Original transcript before refinement (if refinement was applied)
    var originalTranscript: String?
    var originalTranscriptBlocks: [TranscriptBlock]?
    var isRefined: Bool = false  // Whether this transcript has been refined
    
    let hasAudio: Bool
    let hasMicrophone: Bool
    let duration: TimeInterval?  // Duration in seconds
    let wordCount: Int?          // Word count from transcript
    
    init(
        id: UUID = UUID(),
        title: String,
        date: Date,
        directory: URL,
        transcript: String? = nil,
        transcriptBlocks: [TranscriptBlock]? = nil,
        originalTranscript: String? = nil,
        originalTranscriptBlocks: [TranscriptBlock]? = nil,
        isRefined: Bool = false,
        hasAudio: Bool,
        hasMicrophone: Bool,
        duration: TimeInterval? = nil,
        wordCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.directory = directory
        self.transcript = transcript
        self.transcriptBlocks = transcriptBlocks
        self.originalTranscript = originalTranscript
        self.originalTranscriptBlocks = originalTranscriptBlocks
        self.isRefined = isRefined
        self.hasAudio = hasAudio
        self.hasMicrophone = hasMicrophone
        self.duration = duration
        self.wordCount = wordCount
    }
    
    // MARK: - Formatted Properties
    
    /// Returns formatted duration string (e.g., "47 min", "1h 23 min")
    var formattedDuration: String? {
        guard let duration = duration, duration > 0 else { return nil }
        let totalMinutes = Int(duration / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        
        if hours > 0 {
            return "\(hours)h \(minutes) min"
        } else {
            return "\(minutes) min"
        }
    }
    
    /// Returns formatted word count string (e.g., "1,240 words")
    var formattedWordCount: String? {
        guard let wordCount = wordCount, wordCount > 0 else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        guard let formattedNumber = formatter.string(from: NSNumber(value: wordCount)) else {
            return "\(wordCount) words"
        }
        return "\(formattedNumber) words"
    }
    
    // MARK: - Hashable
    
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    nonisolated static func == (lhs: MeetingHistoryItem, rhs: MeetingHistoryItem) -> Bool {
        lhs.id == rhs.id
    }
}

/// Helper struct for grouping meetings by date
struct MeetingHistoryGroup: Identifiable {
    let id: UUID = UUID()
    let date: Date
    let label: String
    var meetings: [MeetingHistoryItem]
}
