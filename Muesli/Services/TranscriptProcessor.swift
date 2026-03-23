import Foundation

/// Processes raw transcript segments into merged, filtered blocks
/// Handles artifact filtering and speaker-based merging logic
@Observable
@MainActor
final class TranscriptProcessor {
    // MARK: - Configuration

    /// Maximum words per block during live streaming display
    private let maxWordsPerBlock: Int = 75

    /// Target number of sentences per finalized block
    private let targetSentencesPerBlock: Int = 4

    /// Hard word-count ceiling for finalized blocks (prevents walls of text)
    private let maxWordsAfterConsolidation: Int = 120

    /// Minimum words in a block before absent punctuation is treated as a natural stop.
    /// Below this threshold a block without sentence-ending punctuation is a fragment
    /// and gets merged with the next same-speaker block.
    private let minWordsToStandAlone: Int = 60

    // MARK: - State

    /// Current blocks being built
    private(set) var blocks: [TranscriptBlock] = []

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
    /// Filters artifacts and appends to the live block list.
    /// Call finalize() when all segments are processed to get consolidated blocks.
    /// - Parameter segment: Raw segment from TranscriptionService
    func processSegment(_ segment: TranscriptionService.TranscriptSegment) {
        guard let cleanedText = filterArtifacts(segment.text) else { return }
        guard !cleanedText.isEmpty else { return }

        let cleanedSegment = TranscriptionService.TranscriptSegment(
            text: cleanedText,
            timestamp: segment.timestamp,
            speaker: segment.speaker
        )
        addSegmentToBlocks(cleanedSegment)
    }

    /// Finalize processing — consolidates blocks into cohesive speaker turns.
    /// Must be called once after all segments have been processed.
    func finalize() {
        consolidateBlocks()
    }

    /// Merge settled blocks (all except the last/active block) during live recording.
    /// Called automatically when a new block is created, so the previously-active block
    /// becomes eligible for merging. O(n) string ops — microseconds even for hundreds of blocks.
    func consolidateSettledBlocks() {
        guard blocks.count >= 2 else { return }

        let activeBlock = blocks.removeLast()
        consolidateBlocks()
        blocks.append(activeBlock)
    }

    /// Return a fully consolidated copy of all blocks (including the active block)
    /// for clipboard use, without mutating live state.
    func consolidatedBlocksSnapshot() -> [TranscriptBlock] {
        var result: [TranscriptBlock] = []

        for block in blocks {
            if let last = result.last,
               last.speaker == block.speaker,
               last.wordCount + block.wordCount <= maxWordsAfterConsolidation,
               !endsSentence(last.text) || sentenceCount(last.text) < targetSentencesPerBlock {
                result[result.count - 1].append(block.text, endTimestamp: block.endTimestamp)
            } else {
                result.append(block)
            }
        }

        return result
    }

    /// Reset processor state
    func reset() {
        blocks.removeAll()
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
        // e.g. "Thank you. Thank you. Thank you." or "Yes. Yes. Yes. Yes."
        if words.count >= 3 {
            // Check all-same-word: "yes yes yes yes"
            if let firstWord = words.first, words.allSatisfy({ $0 == firstWord }) {
                return true
            }

            // Check dominant-word repetition: if any single word makes up >= 60% of
            // all words, it's almost certainly a hallucination (e.g. "yes of course yes yes yes")
            var wordCounts: [String: Int] = [:]
            for word in words { wordCounts[word, default: 0] += 1 }
            if let maxCount = wordCounts.values.max(),
               Double(maxCount) / Double(words.count) >= 0.6,
               words.count >= 4 {
                return true
            }

            // Check repeating n-gram pattern: "thank you thank you thank you"
            // Look for 1-3 word phrases that repeat 3+ times consecutively
            for gramSize in 1...min(3, words.count / 3) {
                var repeatCount = 1
                var maxRepeat = 1
                let gram = Array(words.prefix(gramSize))
                var i = gramSize
                while i + gramSize <= words.count {
                    let next = Array(words[i..<(i + gramSize)])
                    if next == gram {
                        repeatCount += 1
                        maxRepeat = max(maxRepeat, repeatCount)
                    } else {
                        repeatCount = 1
                    }
                    i += gramSize
                }
                if maxRepeat >= 3 {
                    return true
                }
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

    /// Add a segment to the blocks array.
    /// Creates a new block on speaker switch or when the live word limit is reached.
    /// consolidateBlocks() later merges these into cohesive finalized blocks.
    private func addSegmentToBlocks(_ segment: TranscriptionService.TranscriptSegment) {
        let speaker = TranscriptBlock.Speaker(from: segment.speaker)
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let timestamp = segment.timestamp

        guard !text.isEmpty else { return }

        if let lastBlock = blocks.last,
           lastBlock.speaker == speaker,
           lastBlock.wordCount < maxWordsPerBlock {
            blocks[blocks.count - 1].append(text, endTimestamp: timestamp)
        } else {
            blocks.append(TranscriptBlock(
                speaker: speaker,
                text: text,
                startTimestamp: timestamp
            ))
            // New block created — merge settled blocks (all except the new active block)
            consolidateSettledBlocks()
        }
    }

    /// Merge consecutive same-speaker blocks into cohesive speaker turns.
    ///
    /// Merge rule (applied per consecutive same-speaker pair):
    ///   Merge if the previous block does NOT yet end at a sentence boundary,
    ///   OR if it has fewer than targetSentencesPerBlock complete sentences —
    ///   PROVIDED the combined word count stays under maxWordsAfterConsolidation.
    ///
    /// This guarantees:
    ///   - Every block ends with a sentence-ending punctuation mark (. ! ? …)
    ///   - Blocks accumulate up to ~4 sentences before a new block starts
    ///   - No block exceeds the hard word cap (prevents walls of text)
    private func consolidateBlocks() {
        var result: [TranscriptBlock] = []

        for block in blocks {
            if let last = result.last,
               last.speaker == block.speaker,
               last.wordCount + block.wordCount <= maxWordsAfterConsolidation {
                let shouldMerge: Bool
                if endsSentence(last.text) {
                    // Clean sentence boundary: continue accumulating until target paragraph size
                    shouldMerge = sentenceCount(last.text) < targetSentencesPerBlock
                } else {
                    // No punctuation: merge only if block is too short to stand alone.
                    // Long unpunctuated blocks are WhisperKit's limitation — stop here.
                    shouldMerge = last.wordCount < minWordsToStandAlone
                }
                if shouldMerge {
                    result[result.count - 1].append(block.text, endTimestamp: block.endTimestamp)
                } else {
                    result.append(block)
                }
            } else {
                result.append(block)
            }
        }

        blocks = result
    }

    /// Returns true if text ends with sentence-ending punctuation
    private func endsSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        return last == "." || last == "!" || last == "?" || last == "…"
    }

    /// Count the number of complete sentences in text
    private func sentenceCount(_ text: String) -> Int {
        text.filter { $0 == "." || $0 == "!" || $0 == "?" || $0 == "…" }.count
    }
}
