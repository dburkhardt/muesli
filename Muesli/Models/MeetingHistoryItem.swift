import Foundation

/// Represents a single recording segment within a resumable meeting
struct TranscriptSegment: Identifiable, Codable, Equatable {
    let id: UUID
    let segmentNumber: Int  // 1, 2, 3, etc.
    var originalBlocks: [TranscriptBlock]  // Raw transcript for this segment
    var refinedBlocks: [TranscriptBlock]?  // Refined transcript for this segment, nil if not yet refined
    var isRefined: Bool  // Whether this segment has been refined
    let startTime: Date  // When this segment started recording
    
    init(
        id: UUID = UUID(),
        segmentNumber: Int,
        originalBlocks: [TranscriptBlock],
        refinedBlocks: [TranscriptBlock]? = nil,
        isRefined: Bool = false,
        startTime: Date
    ) {
        self.id = id
        self.segmentNumber = segmentNumber
        self.originalBlocks = originalBlocks
        self.refinedBlocks = refinedBlocks
        self.isRefined = isRefined
        self.startTime = startTime
    }
}

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
    var isLoadingTranscript: Bool = false  // Whether transcript is currently being loaded
    
    // Reprocessing state (for re-transcribing with different models)
    var isReprocessing: Bool = false  // Whether this meeting is currently being reprocessed
    var reprocessingProgress: Double = 0.0  // Progress of reprocessing (0.0 to 1.0)
    
    // Original transcript before refinement (if refinement was applied)
    var originalTranscript: String?
    var originalTranscriptBlocks: [TranscriptBlock]?
    var isRefined: Bool = false  // Whether this transcript has been refined
    
    // MARK: - Resume State
    
    /// Whether this meeting can be resumed (has audio files to continue from)
    var canResume: Bool {
        hasAudio || hasMicrophone
    }
    
    /// Number of recording segments (1 = single recording, 2+ = resumed)
    var segmentCount: Int = 1
    
    /// Transcript segments with per-segment original/refined blocks
    var transcriptSegments: [TranscriptSegment] = []
    
    /// Whether to show refined transcript (applies globally to all segments)
    var isShowingRefined: Bool = false
    
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
        segmentCount: Int = 1,
        transcriptSegments: [TranscriptSegment] = [],
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
        self.segmentCount = segmentCount
        self.transcriptSegments = transcriptSegments
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
