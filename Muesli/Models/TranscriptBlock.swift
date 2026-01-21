import Foundation

/// Represents a merged transcript block for display
/// Multiple raw transcript segments from WhisperKit are combined into blocks
/// based on speaker continuity and word count limits
struct TranscriptBlock: Identifiable, Codable, Equatable {
    let id: UUID
    let speaker: Speaker
    var text: String
    let startTimestamp: TimeInterval
    var endTimestamp: TimeInterval
    
    enum Speaker: String, Codable, Equatable {
        case me = "Me"
        case them = "Them"
    }
    
    /// Computed word count for display and merging decisions
    var wordCount: Int {
        text.split(separator: " ").count
    }
    
    /// Format timestamp as MM:SS
    var formattedStartTime: String {
        let mins = Int(startTimestamp) / 60
        let secs = Int(startTimestamp) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
    
    /// Format timestamp range as MM:SS - MM:SS
    var formattedTimeRange: String {
        let startMins = Int(startTimestamp) / 60
        let startSecs = Int(startTimestamp) % 60
        let endMins = Int(endTimestamp) / 60
        let endSecs = Int(endTimestamp) % 60
        return String(format: "%02d:%02d - %02d:%02d", startMins, startSecs, endMins, endSecs)
    }
    
    init(
        id: UUID = UUID(),
        speaker: Speaker,
        text: String,
        startTimestamp: TimeInterval,
        endTimestamp: TimeInterval? = nil
    ) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp ?? startTimestamp
    }
    
    /// Append text to this block and update end timestamp
    mutating func append(_ additionalText: String, endTimestamp: TimeInterval) {
        // Add space between existing text and new text if needed
        if !text.isEmpty && !additionalText.isEmpty {
            text += " " + additionalText
        } else {
            text += additionalText
        }
        self.endTimestamp = endTimestamp
    }
}

// MARK: - Conversion from TranscriptionService.TranscriptSegment

extension TranscriptBlock.Speaker {
    /// Convert from TranscriptionService speaker type
    init(from servicesSpeaker: TranscriptionService.TranscriptSegment.Speaker) {
        switch servicesSpeaker {
        case .me:
            self = .me
        case .them:
            self = .them
        }
    }
}
