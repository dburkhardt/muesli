import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Service for refining transcripts using LLM
/// Cleans up transcripts, fixes grammar, improves flow
@Observable
@MainActor
final class TranscriptRefinementService {
    // MARK: - Dependencies
    
    private let llmManager: LLMManager
    
    // MARK: - State
    
    var isRefining: Bool = false
    var progress: Double = 0.0
    var errorMessage: String?
    
    // MARK: - Configuration
    
    /// Maximum tokens to generate for refinement
    private let maxGenerationTokens: Int = 2048
    
    /// Maximum characters to refine in a single batch (~1000 tokens input)
    /// Used for speaker-threaded batch processing
    private let maxBatchCharacters: Int = 4000
    
    // MARK: - Initialization
    
    init(llmManager: LLMManager) {
        self.llmManager = llmManager
    }
    
    // MARK: - Public Methods
    
    /// Refine transcript blocks using LLM with speaker-threaded batch processing
    /// Separates blocks by speaker ("Me" vs "Them"), refines each thread independently
    /// with batched LLM calls, then merges results chronologically.
    /// - Parameter blocks: Array of transcript blocks to refine
    /// - Returns: Refined transcript blocks
    func refineTranscript(_ blocks: [TranscriptBlock]) async throws -> [TranscriptBlock] {
        guard !blocks.isEmpty else { return blocks }
        
        isRefining = true
        progress = 0.0
        errorMessage = nil
        
        defer {
            isRefining = false
            progress = 0.0
        }
        
        guard llmManager.isLLMAvailable && llmManager.isLLMStitchingEnabled else {
            // No LLM available, return blocks as-is
            return blocks
        }
        
        guard let container = llmManager.modelContainer else {
            throw LLMManager.LLMError.modelNotLoaded
        }
        
        // Split by speaker
        let (meBlocks, themBlocks) = splitBlocksBySpeaker(blocks)
        
        // Calculate progress ranges based on block distribution
        let totalBlocks = meBlocks.count + themBlocks.count
        let meProgress = totalBlocks > 0 ? Double(meBlocks.count) / Double(totalBlocks) : 0.5
        
        // Refine "Me" thread (progress 0.0 - meProgress)
        let refinedMe = try await refineSpeakerThread(
            meBlocks,
            speaker: .me,
            container: container,
            progressRange: (0.0, meProgress)
        )
        
        // Refine "Them" thread (progress meProgress - 1.0)
        let refinedThem = try await refineSpeakerThread(
            themBlocks,
            speaker: .them,
            container: container,
            progressRange: (meProgress, 1.0)
        )
        
        // Merge back chronologically by original index
        var result = blocks // Start with original blocks as base
        for (index, block) in refinedMe {
            result[index] = block
        }
        for (index, block) in refinedThem {
            result[index] = block
        }
        
        progress = 1.0
        return result
    }
    
    /// Refine plain text transcript using LLM
    /// - Parameter text: Plain text transcript to refine
    /// - Returns: Refined transcript text
    func refineTranscript(_ text: String) async throws -> String {
        guard !text.isEmpty else { return text }
        
        isRefining = true
        progress = 0.0
        errorMessage = nil
        
        defer {
            isRefining = false
            progress = 0.0
        }
        
        guard llmManager.isLLMAvailable && llmManager.isLLMStitchingEnabled else {
            // No LLM available, return text as-is
            return text
        }
        
        guard let container = llmManager.modelContainer else {
            throw LLMManager.LLMError.modelNotLoaded
        }
        
        progress = 0.5
        let refinedText = try await refineBlockText(text, container: container)
        progress = 1.0

        return refinedText
    }

    /// Refine transcript by consolidating fragmented same-speaker turns into cohesive paragraphs
    /// Sends the full conversation to the LLM for holistic restructuring
    /// - Parameter blocks: Array of transcript blocks to consolidate and refine
    /// - Returns: Consolidated and refined transcript blocks
    func consolidateAndRefineTranscript(_ blocks: [TranscriptBlock]) async throws -> [TranscriptBlock] {
        guard !blocks.isEmpty else { return blocks }

        isRefining = true
        progress = 0.0
        errorMessage = nil

        defer {
            isRefining = false
            progress = 0.0
        }

        guard llmManager.isLLMAvailable && llmManager.isLLMStitchingEnabled else {
            return blocks
        }

        guard let container = llmManager.modelContainer else {
            throw LLMManager.LLMError.modelNotLoaded
        }

        // Serialize all blocks to structured text
        let inputText = blocks.map { block in
            "**\(block.speaker.rawValue)** _[\(block.formattedStartTime)]_\n\n\(block.text)"
        }.joined(separator: "\n\n")

        progress = 0.3

        let result = try await container.perform { context in
            let systemMessage = """
                You are a transcript editor. Restructure this meeting transcript so that consecutive turns \
                from the same speaker are merged into cohesive paragraphs of 3-4 sentences. Rules:
                - Keep ALL spoken content — do not delete or summarize anything
                - Merge consecutive same-speaker fragments into one paragraph
                - Fix grammar and remove filler words (um, uh, like, you know)
                - Keep the speaker label (**Me** or **Them**) and the timestamp of the FIRST fragment in each merged group
                - Output in the same format: **Speaker** _[MM:SS]_ followed by a blank line and paragraph text
                - Do not add information or change meaning
                """

            let messages: [Chat.Message] = [
                .system(systemMessage),
                .user(inputText)
            ]

            let userInput = UserInput(chat: messages)
            let input = try await context.processor.prepare(input: userInput)

            let generateParams = GenerateParameters(
                maxTokens: 4096,
                temperature: 0.2
            )

            let cache = context.model.newCache(parameters: generateParams)
            let iterator = try TokenIterator(
                input: input,
                model: context.model,
                cache: cache,
                parameters: generateParams
            )

            let generateResult: GenerateResult = generate(
                input: input,
                context: context,
                iterator: iterator
            ) { _ in .more }

            Stream.gpu.synchronize()
            return generateResult.output
        }

        progress = 0.8

        let output = result.trimmingCharacters(in: .whitespacesAndNewlines)

        // Fall back to original if LLM returned nothing useful
        guard !output.isEmpty, output.count > inputText.count / 4 else {
            return blocks
        }

        // Parse LLM output back into TranscriptBlocks
        let parsedBlocks = parseConsolidatedOutput(output, originalBlocks: blocks)

        // Validate with consolidation guardrails (allows fewer blocks than input)
        if passesConsolidationGuardrails(originalBlocks: blocks, candidateBlocks: parsedBlocks) {
            progress = 1.0
            return parsedBlocks
        }

        // Guardrails failed — return original
        return blocks
    }

    // MARK: - Guardrails
    
    /// Validates that LLM output preserves required structure (speaker labels, timestamps)
    /// and doesn't excessively rewrite the original text.
    func passesGuardrails(original: String, candidate: String) -> Bool {
        guard !original.isEmpty else { return true }
        
        let speakerPattern = #"\*\*(Me|Them)\*\*"#
        let timestampPattern = #"_\[[\d:]+\]_"#
        
        let originalSpeakers = matches(for: speakerPattern, in: original)
        let candidateSpeakers = matches(for: speakerPattern, in: candidate)
        if !originalSpeakers.isEmpty && candidateSpeakers.count < originalSpeakers.count {
            return false
        }
        
        let originalTimestamps = matches(for: timestampPattern, in: original)
        let candidateTimestamps = matches(for: timestampPattern, in: candidate)
        if !originalTimestamps.isEmpty && candidateTimestamps.count < originalTimestamps.count {
            return false
        }
        
        let originalWords = original.split(separator: " ")
        let candidateWords = candidate.split(separator: " ")
        guard !originalWords.isEmpty else { return true }
        
        let commonCount = longestCommonSubsequenceCount(Array(originalWords), Array(candidateWords))
        let editRatio = 1.0 - (Double(commonCount) / Double(originalWords.count))
        let maxAllowedEditRatio = 0.5
        return editRatio <= maxAllowedEditRatio
    }
    
    private func matches(for pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }
    
    private func longestCommonSubsequenceCount<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        let m = a.count, n = b.count
        guard m > 0, n > 0 else { return 0 }
        var prev = [Int](repeating: 0, count: n + 1)
        var curr = [Int](repeating: 0, count: n + 1)
        for i in 1...m {
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    curr[j] = prev[j - 1] + 1
                } else {
                    curr[j] = max(prev[j], curr[j - 1])
                }
            }
            prev = curr
            curr = [Int](repeating: 0, count: n + 1)
        }
        return prev[n]
    }
    
    // MARK: - Private Methods
    
    private func refineBlockText(
        _ text: String,
        container: ModelContainer,
        speaker: TranscriptBlock.Speaker? = nil
    ) async throws -> String {
        let prompt = buildRefinementPrompt(text, speaker: speaker)
        
        let result = try await container.perform { context in
            // Prepare input messages
            let systemMessage = """
                You are a transcript editor. Your job is to clean up transcriptions by fixing grammar, \
                removing filler words (um, uh, like), improving sentence flow, and making the text more readable. \
                Do not change the meaning or add information. Output only the cleaned text, nothing else.
                """
            let messages: [Chat.Message] = [
                .system(systemMessage),
                .user(prompt)
            ]
            
            let userInput = UserInput(chat: messages)
            let input = try await context.processor.prepare(input: userInput)
            
            // Generate parameters
            let generateParams = GenerateParameters(
                maxTokens: self.maxGenerationTokens,
                temperature: 0.2  // Low temperature for consistent output
            )
            
            // Create cache and iterator
            let cache = context.model.newCache(parameters: generateParams)
            let iterator = try TokenIterator(
                input: input,
                model: context.model,
                cache: cache,
                parameters: generateParams
            )
            
            // Generate and collect output
            let generateResult: GenerateResult = generate(
                input: input,
                context: context,
                iterator: iterator
            ) { _ in .more }
            
            // Synchronize GPU before returning
            Stream.gpu.synchronize()
            
            return generateResult.output
        }
        
        // Clean up the result
        let cleaned = result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        
        // If LLM returned empty or suspiciously short result, return original
        if cleaned.isEmpty || cleaned.count < text.count / 4 {
            return text
        }
        
        return cleaned
    }
    
    private func buildRefinementPrompt(
        _ text: String,
        speaker: TranscriptBlock.Speaker? = nil
    ) -> String {
        let speakerContext: String
        if let speaker = speaker {
            switch speaker {
            case .me:
                speakerContext = """
                    This is the user's own speech (first-person). Focus on fixing first-person statements, \
                    removing filler words (um, uh, like, you know), and improving sentence flow.
                    """
            case .them:
                speakerContext = """
                    This is speech from remote participants. There may be multiple speakers - \
                    preserve all distinct contributions. Focus on clarity and natural flow.
                    """
            }
        } else {
            speakerContext = "Fix grammar, remove filler words, and improve readability."
        }
        
        return """
        Clean up this transcript. \(speakerContext) Do not change the meaning or add information:
        
        \(text)
        
        Cleaned transcript:
        """
    }
    
    // MARK: - Speaker Thread Processing
    
    /// Splits blocks into separate speaker threads while preserving original indices
    private func splitBlocksBySpeaker(
        _ blocks: [TranscriptBlock]
    ) -> (me: [(Int, TranscriptBlock)], them: [(Int, TranscriptBlock)]) {
        var meBlocks: [(Int, TranscriptBlock)] = []
        var themBlocks: [(Int, TranscriptBlock)] = []
        
        for (index, block) in blocks.enumerated() {
            if block.speaker == .me {
                meBlocks.append((index, block))
            } else {
                themBlocks.append((index, block))
            }
        }
        
        return (meBlocks, themBlocks)
    }
    
    /// Refine blocks for a single speaker thread using batched LLM calls
    /// - Parameters:
    ///   - indexedBlocks: Array of (originalIndex, block) tuples
    ///   - speaker: The speaker type for prompt customization
    ///   - container: The LLM model container
    ///   - progressRange: Progress range to report (start, end) within 0.0-1.0
    /// - Returns: Array of (originalIndex, refinedBlock) tuples
    private func refineSpeakerThread(
        _ indexedBlocks: [(Int, TranscriptBlock)],
        speaker: TranscriptBlock.Speaker,
        container: ModelContainer,
        progressRange: (start: Double, end: Double)
    ) async throws -> [(Int, TranscriptBlock)] {
        guard !indexedBlocks.isEmpty else { return [] }
        
        // Batch blocks by character count
        var batches: [[(Int, TranscriptBlock)]] = []
        var currentBatch: [(Int, TranscriptBlock)] = []
        var currentBatchCharCount = 0
        
        for indexedBlock in indexedBlocks {
            let blockCharCount = indexedBlock.1.text.count
            
            // Start new batch if adding this block would exceed limit
            if currentBatchCharCount + blockCharCount > maxBatchCharacters && !currentBatch.isEmpty {
                batches.append(currentBatch)
                currentBatch = []
                currentBatchCharCount = 0
            }
            
            currentBatch.append(indexedBlock)
            currentBatchCharCount += blockCharCount
        }
        
        // Add final batch
        if !currentBatch.isEmpty {
            batches.append(currentBatch)
        }
        
        // Process each batch
        var refinedBlocks: [(Int, TranscriptBlock)] = []
        let progressPerBatch = (progressRange.end - progressRange.start) / Double(batches.count)
        
        for (batchIndex, batch) in batches.enumerated() {
            // Update progress
            progress = progressRange.start + Double(batchIndex) * progressPerBatch
            
            // Combine batch text for single LLM call
            let batchText = batch.map { $0.1.text }.joined(separator: " ")
            let trimmedBatchText = batchText.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Skip LLM call if batch has no meaningful content (empty or very short)
            // Short text (< 10 chars) often produces LLM hallucinations like "no transcript provided"
            if trimmedBatchText.isEmpty || trimmedBatchText.count < 10 {
                // Return original blocks unchanged
                for (originalIndex, originalBlock) in batch {
                    refinedBlocks.append((originalIndex, originalBlock))
                }
                continue
            }
            
            let originalBlocks = batch.map { $0.1 }
            
            // Refine the batch
            let refinedText = try await refineBlockText(batchText, container: container, speaker: speaker)
            
            // Split refined text back into blocks
            let splitTexts = splitRefinedText(refinedText, originalBlocks: originalBlocks)
            
            // Create refined blocks with original indices
            for (i, (originalIndex, originalBlock)) in batch.enumerated() {
                var refinedBlock = originalBlock
                refinedBlock.text = splitTexts[i]
                refinedBlocks.append((originalIndex, refinedBlock))
            }
        }
        
        return refinedBlocks
    }
    
    /// Splits refined text back into blocks based on original block structure
    /// Uses original word counts as guides for proportional splitting
    private func splitRefinedText(_ refinedText: String, originalBlocks: [TranscriptBlock]) -> [String] {
        guard originalBlocks.count > 1 else {
            // Single block - return entire refined text
            return [refinedText.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        
        // Calculate original word counts and total
        let originalWordCounts = originalBlocks.map { $0.wordCount }
        let totalOriginalWords = originalWordCounts.reduce(0, +)
        
        guard totalOriginalWords > 0 else {
            // Empty blocks - distribute evenly
            return originalBlocks.map { _ in "" }
        }
        
        // Split refined text into sentences for better distribution
        let sentences = splitIntoSentences(refinedText)
        
        guard !sentences.isEmpty else {
            return originalBlocks.map { _ in "" }
        }
        
        // Calculate word count for each sentence
        let sentenceWordCounts = sentences.map { $0.split(separator: " ").count }
        let totalRefinedWords = sentenceWordCounts.reduce(0, +)
        
        // Distribute sentences to blocks proportionally based on original word counts
        var result: [String] = []
        var sentenceIndex = 0
        var wordsAssigned = 0
        
        for (blockIndex, originalWordCount) in originalWordCounts.enumerated() {
            // Calculate target words for this block (proportional)
            let proportion = Double(originalWordCount) / Double(totalOriginalWords)
            let targetWords: Int
            
            if blockIndex == originalWordCounts.count - 1 {
                // Last block gets all remaining sentences
                targetWords = totalRefinedWords - wordsAssigned
            } else {
                targetWords = Int(Double(totalRefinedWords) * proportion)
            }
            
            // Collect sentences until we reach target
            var blockSentences: [String] = []
            var blockWordCount = 0
            
            while sentenceIndex < sentences.count {
                let sentenceWords = sentenceWordCounts[sentenceIndex]
                
                // If this is the last block, take all remaining sentences
                if blockIndex == originalWordCounts.count - 1 {
                    blockSentences.append(sentences[sentenceIndex])
                    blockWordCount += sentenceWords
                    sentenceIndex += 1
                }
                // Otherwise, check if we should include this sentence
                else if blockWordCount + sentenceWords <= targetWords || blockSentences.isEmpty {
                    blockSentences.append(sentences[sentenceIndex])
                    blockWordCount += sentenceWords
                    sentenceIndex += 1
                } else {
                    break
                }
            }
            
            wordsAssigned += blockWordCount
            result.append(blockSentences.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        
        return result
    }
    
    /// Split text into sentences for distribution
    private func splitIntoSentences(_ text: String) -> [String] {
        // Split on sentence-ending punctuation while preserving the punctuation
        let pattern = #"(?<=[.!?])\s+"#
        
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [])
            let range = NSRange(text.startIndex..., in: text)
            let results = regex.matches(in: text, options: [], range: range)
            
            var sentences: [String] = []
            var lastEnd = text.startIndex
            
            for match in results {
                if let matchRange = Range(match.range, in: text) {
                    let sentence = String(text[lastEnd..<matchRange.lowerBound])
                    if !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        sentences.append(sentence.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    lastEnd = matchRange.upperBound
                }
            }
            
            // Add remaining text as final sentence
            let remaining = String(text[lastEnd...])
            if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sentences.append(remaining.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            
            return sentences
        } catch {
            // Fallback: return entire text as single sentence
            return [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
    }

    /// Parse holistic LLM output back into TranscriptBlock array
    private func parseConsolidatedOutput(
        _ output: String,
        originalBlocks: [TranscriptBlock]
    ) -> [TranscriptBlock] {
        let headerPattern = #"\*\*(Me|Them)\*\*\s+_\[(\d{1,2}):(\d{2})\]_"#
        guard let regex = try? NSRegularExpression(pattern: headerPattern) else {
            return originalBlocks
        }

        let nsOutput = output as NSString
        let range = NSRange(output.startIndex..., in: output)
        let headerMatches = regex.matches(in: output, range: range)

        guard !headerMatches.isEmpty else { return originalBlocks }

        var result: [TranscriptBlock] = []

        for (i, match) in headerMatches.enumerated() {
            guard let speakerRange = Range(match.range(at: 1), in: output),
                  let minsRange = Range(match.range(at: 2), in: output),
                  let secsRange = Range(match.range(at: 3), in: output) else {
                continue
            }

            let speakerString = String(output[speakerRange])
            let mins = Int(output[minsRange]) ?? 0
            let secs = Int(output[secsRange]) ?? 0
            let timestamp = TimeInterval(mins * 60 + secs)

            // Find text content: from end of this header to start of next header (or end of output)
            let contentStart = match.range.upperBound
            let contentEnd: Int
            if i + 1 < headerMatches.count {
                contentEnd = headerMatches[i + 1].range.lowerBound
            } else {
                contentEnd = nsOutput.length
            }

            let contentNSRange = NSRange(location: contentStart, length: contentEnd - contentStart)
            guard let contentRange = Range(contentNSRange, in: output) else { continue }

            let text = String(output[contentRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else { continue }

            let speaker: TranscriptBlock.Speaker = speakerString == "Me" ? .me : .them

            // Use end timestamp from closest original block
            let endTimestamp = originalBlocks
                .min(by: { abs($0.startTimestamp - timestamp) < abs($1.startTimestamp - timestamp) })?
                .endTimestamp ?? timestamp

            result.append(TranscriptBlock(
                speaker: speaker,
                text: text,
                startTimestamp: timestamp,
                endTimestamp: endTimestamp
            ))
        }

        return result.isEmpty ? originalBlocks : result
    }

    /// Validate consolidated output — allows fewer blocks than input (intentional for consolidation)
    /// Requires all original speakers to be represented and word count within 50% of original
    private func passesConsolidationGuardrails(
        originalBlocks: [TranscriptBlock],
        candidateBlocks: [TranscriptBlock]
    ) -> Bool {
        guard !candidateBlocks.isEmpty else { return false }

        // All original speakers must be represented in output
        let originalSpeakers = Set(originalBlocks.map { $0.speaker })
        let candidateSpeakers = Set(candidateBlocks.map { $0.speaker })
        guard originalSpeakers.isSubset(of: candidateSpeakers) else { return false }

        // Output word count must not be drastically lower (> 50% reduction signals dropped content)
        let originalWords = originalBlocks.reduce(0) { $0 + $1.wordCount }
        let candidateWords = candidateBlocks.reduce(0) { $0 + $1.wordCount }
        guard originalWords == 0 || Double(candidateWords) >= Double(originalWords) * 0.5 else {
            return false
        }

        return true
    }
}
