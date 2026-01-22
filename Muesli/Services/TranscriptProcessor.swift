import Foundation

/// Processes raw transcript segments into merged, filtered blocks
/// Handles artifact filtering and speaker-based merging logic
@Observable
@MainActor
final class TranscriptProcessor {
    // MARK: - Configuration
    
    /// Maximum words per block before forcing a split
    private let maxWordsPerBlock: Int = 75
    
    /// Minimum words from other speaker to end current block
    /// (brief interjections like "uh-huh" don't break flow)
    private let minWordsToBreakFlow: Int = 10
    
    // MARK: - State
    
    /// Current blocks being built
    private(set) var blocks: [TranscriptBlock] = []
    
    /// Pending segment from other speaker (held to see if it's a brief interjection)
    private var pendingInterjection: TranscriptionService.TranscriptSegment?
    
    // MARK: - Artifact Filtering
    
    /// Combined regex for artifact detection (compiled once)
    /// Catches Whisper's non-speech annotations in parentheses and brackets
    private let artifactRegex: NSRegularExpression? = {
        let patterns = [
            // Specific common artifacts
            "\\(silence\\)",
            "\\(music\\)",
            "\\(static\\)",
            "\\(background noise\\)",
            "\\(background\\)",
            "\\(inaudible\\)",
            "\\(unintelligible\\)",
            "\\(applause\\)",
            "\\(laughter\\)",
            "\\(coughing\\)",
            "\\(sighing\\)",
            "\\(breathing\\)",
            
            // General patterns for Whisper sound descriptions
            "\\([^)]*\\b\\w+ing\\b[^)]*\\)",  // Any parenthetical with -ing word
            // Sound words (whistle, siren, bell, etc.)
            "\\([^)]*\\b(whistle|siren|bell|chime|horn|alarm|beep|buzz|click|bang|crash|thud)\\b[^)]*\\)",
            // Generic subjects often in annotations
            "\\([^)]*\\b(audience|crowd|people|someone|something)\\b[^)]*\\)",
            
            // Bracketed annotations
            "\\[.*?\\]",  // Any bracketed annotation (non-greedy)
            
            // Other artifacts
            "\\(.*?noise.*?\\)",
            "\\(.*?sound.*?\\)",
            "\\(.*?playing.*?\\)",
            "\\(.*?speaking.*?foreign.*?\\)",
            "♪[^♪]*♪",  // Music notes
            "\\.\\.\\.$"  // Trailing ellipsis only
        ]
        let pattern = patterns.joined(separator: "|")
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()
    
    // MARK: - Public Methods
    
    /// Process a new transcript segment
    /// - Parameter segment: Raw segment from TranscriptionService
    func processSegment(_ segment: TranscriptionService.TranscriptSegment) {
        // Filter artifacts
        guard let cleanedText = filterArtifacts(segment.text) else {
            return // Segment was entirely artifacts
        }
        
        // Skip empty segments
        guard !cleanedText.isEmpty else { return }
        
        let speaker = TranscriptBlock.Speaker(from: segment.speaker)
        
        // Handle pending interjection if exists
        if let pending = pendingInterjection {
            let pendingSpeaker = TranscriptBlock.Speaker(from: pending.speaker)
            
            if pendingSpeaker == speaker {
                // Same speaker continues - interjection was from other speaker
                // Add the pending interjection first, then this segment
                addSegmentToBlocks(pending)
                pendingInterjection = nil
            } else {
                // Different speaker - check if pending was brief
                let pendingWords = pending.text.split(separator: " ").count
                if pendingWords < minWordsToBreakFlow {
                    // Brief interjection - don't break the flow, discard pending
                    pendingInterjection = nil
                } else {
                    // Substantial speech - add it
                    addSegmentToBlocks(pending)
                    pendingInterjection = nil
                }
            }
        }
        
        // Create modified segment with cleaned text
        let cleanedSegment = TranscriptionService.TranscriptSegment(
            text: cleanedText,
            timestamp: segment.timestamp,
            speaker: segment.speaker
        )
        
        addSegmentToBlocks(cleanedSegment)
    }
    
    /// Finalize processing - flush any pending content
    func finalize() {
        if let pending = pendingInterjection {
            addSegmentToBlocks(pending)
            pendingInterjection = nil
        }
    }
    
    /// Reset processor state
    func reset() {
        blocks.removeAll()
        pendingInterjection = nil
    }
    
    /// Get formatted transcript text for file output
    func formattedTranscript(title: String, date: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let dateString = dateFormatter.string(from: date)
        
        var output = "# \(title)\n\(dateString)\n\n## Transcript\n\n"
        
        for block in blocks {
            output += "**\(block.speaker.rawValue)** [\(block.formattedStartTime)]\n"
            output += "\(block.text)\n\n"
        }
        
        return output
    }
    
    // MARK: - Private Methods
    
    /// Filter artifacts from text, returning nil if entire text is artifacts
    private func filterArtifacts(_ text: String) -> String? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // First, remove WhisperKit special tokens
        // These appear in segment-level text: <|startoftranscript|>, <|en|>, <|transcribe|>,
        // <|0.00|>, <|endoftext|>, <|notimestamps|>, etc.
        cleaned = removeWhisperKitTokens(cleaned)
        
        // Check for common Whisper hallucinations on silence first
        if isHallucination(cleaned) {
            return nil
        }
        
        guard let regex = artifactRegex else { return cleaned }
        
        // Remove all artifact patterns
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        cleaned = regex.stringByReplacingMatches(
            in: cleaned,
            options: [],
            range: range,
            withTemplate: ""
        )
        
        // Clean up extra whitespace
        cleaned = cleaned
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        return cleaned.isEmpty ? nil : cleaned
    }
    
    /// Remove WhisperKit special tokens from text
    /// These tokens appear in segment-level transcription output
    private func removeWhisperKitTokens(_ text: String) -> String {
        // WhisperKit special token pattern: <|...|>
        // Includes: <|startoftranscript|>, <|en|>, <|transcribe|>, <|translate|>,
        // <|notimestamps|>, <|endoftext|>, and timestamp tokens like <|0.00|>, <|10.00|>
        guard let tokenRegex = try? NSRegularExpression(
            pattern: "<\\|[^|>]+\\|>",
            options: []
        ) else {
            return text
        }
        
        let range = NSRange(text.startIndex..., in: text)
        return tokenRegex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Detect common Whisper hallucinations that occur on silence/blank audio
    private func isHallucination(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Strip end-of-sentence punctuation but preserve hyphens (for "bye-bye", etc.)
        // Only remove: . , ! ? ; : " ' ( ) [ ] { }
        let endPunctuation = CharacterSet(charactersIn: ".,!?;:\"'()[]{}…")
        let cleanedComponents = lower.components(separatedBy: endPunctuation)
        let cleanText = cleanedComponents.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Split into words (punctuation removed but hyphens preserved)
        let words = cleanText.split(separator: " ").map { String($0) }
        
        // Filter very short segments (< 3 words) - often noise at recording boundaries
        if words.count < 3 {
            // Allow short segments that contain actual content words
            // But filter common filler words and noise artifacts
            let fillerWords: Set<String> = [
                "uh", "um", "hmm", "ah", "eh", "oh", "huh", "mhm", "mmm", "yeah", "yep", "nope", "okay"
            ]
            let hasOnlyFiller = words.allSatisfy { fillerWords.contains($0) }
            if hasOnlyFiller {
                return true
            }
        }
        
        // Detect repetitive text (common hallucination pattern)
        // e.g. "Thank you. Thank you. Thank you."
        if let firstWord = words.first, words.count >= 3 {
            let isAllSameWord = words.allSatisfy { $0 == firstWord }
            if isAllSameWord {
                return true
            }
        }
        
        // Detect common Whisper hallucinations on blank audio
        let hallucinations = [
            "thank you",
            "thanks for watching",
            "thank you for watching",
            "subscribe",
            "like and subscribe",
            "bye",
            "bye-bye",
            "goodbye",
            "see you next time",
            "thanks for listening",
            "you",
            "i",
            "the",
            "a"
        ]
        
        // Check against clean text (hyphens preserved)
        if hallucinations.contains(cleanText) {
            return true
        }
        
        return false
    }
    
    /// Add a segment to the blocks array, handling merging logic
    private func addSegmentToBlocks(_ segment: TranscriptionService.TranscriptSegment) {
        let speaker = TranscriptBlock.Speaker(from: segment.speaker)
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let timestamp = segment.timestamp
        
        guard !text.isEmpty else { return }
        
        // Check if we can append to the last block
        if let lastBlock = blocks.last,
           lastBlock.speaker == speaker,
           lastBlock.wordCount < maxWordsPerBlock {
            // Same speaker and under word limit - append
            blocks[blocks.count - 1].append(text, endTimestamp: timestamp)
            
            // Check if we exceeded word limit after appending
            if blocks[blocks.count - 1].wordCount >= maxWordsPerBlock {
                // Block is full - next segment from same speaker starts new block
            }
        } else {
            // Different speaker or word limit exceeded - create new block
            let newBlock = TranscriptBlock(
                speaker: speaker,
                text: text,
                startTimestamp: timestamp
            )
            blocks.append(newBlock)
        }
    }
}
