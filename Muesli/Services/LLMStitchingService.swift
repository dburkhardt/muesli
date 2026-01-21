import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import os.log

/// Service for intelligent transcript chunk stitching
/// Uses local LLM when available, falls back to heuristics otherwise
///
/// Handles:
/// - Duplicate detection at chunk boundaries
/// - Overlap reconciliation
/// - Natural text flow improvement
@MainActor
final class LLMStitchingService {
    // MARK: - Dependencies
    
    private let llmManager: LLMManager
    private let logger = LoggerFactory.logger(category: "LLMStitchingService")
    
    // MARK: - Configuration
    
    /// Minimum similarity ratio to consider text as duplicate (0.0-1.0)
    private let duplicateSimilarityThreshold: Double = 0.7
    
    /// Number of words to check for overlap at boundaries
    private let overlapWindowSize: Int = 10
    
    /// Maximum tokens to generate for stitching
    private let maxGenerationTokens: Int = 512
    
    // MARK: - Initialization
    
    init(llmManager: LLMManager) {
        self.llmManager = llmManager
    }
    
    // MARK: - Public Methods
    
    /// Stitch multiple transcript chunks into coherent text
    /// - Parameter chunks: Array of text chunks to stitch together
    /// - Returns: Stitched, cleaned text
    func stitchChunks(_ chunks: [String]) async -> String {
        guard !chunks.isEmpty else { return "" }
        guard chunks.count > 1 else { return chunks[0] }
        
        // Use LLM if available, otherwise fall back to heuristics
        if llmManager.isLLMAvailable && llmManager.isLLMStitchingEnabled {
            do {
                return try await stitchWithLLM(chunks)
            } catch {
                logger.warning("LLM stitching failed, falling back to heuristics: \(error.localizedDescription)")
                return stitchWithHeuristics(chunks)
            }
        } else {
            return stitchWithHeuristics(chunks)
        }
    }
    
    /// Stitch a new chunk onto existing text
    /// - Parameters:
    ///   - newChunk: New text to append
    ///   - existingText: Existing accumulated text
    /// - Returns: Combined text with overlap handled
    func appendChunk(_ newChunk: String, to existingText: String) async -> String {
        guard !existingText.isEmpty else { return newChunk }
        guard !newChunk.isEmpty else { return existingText }
        
        // For incremental updates, use heuristics for speed
        // LLM is better for batch processing
        return appendWithHeuristics(newChunk, to: existingText)
    }
    
    // MARK: - LLM Stitching
    
    private func stitchWithLLM(_ chunks: [String]) async throws -> String {
        guard let container = llmManager.modelContainer else {
            throw LLMManager.LLMError.modelNotLoaded
        }
        
        let prompt = buildStitchingPrompt(chunks)
        
        // Generate using the model container
        let result = try await container.perform { context in
            // Prepare input messages
            let systemMessage = """
                You are a transcript cleaner. Your job is to merge overlapping transcript chunks into \
                coherent text. Remove duplicated words/phrases at boundaries. Do not add or change content. \
                Output only the cleaned text, nothing else.
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
                temperature: 0.1  // Low temperature for deterministic output
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
        
        // If LLM returned empty or suspiciously short result, fall back to heuristics
        if cleaned.isEmpty || cleaned.count < chunks.joined().count / 4 {
            return stitchWithHeuristics(chunks)
        }
        
        return cleaned
    }
    
    private func buildStitchingPrompt(_ chunks: [String]) -> String {
        """
        Merge these overlapping transcript chunks into coherent text. \
        Remove any duplicated words or phrases at the boundaries:
        
        \(chunks.enumerated().map { "Chunk \($0 + 1): \($1)" }.joined(separator: "\n\n"))
        
        Merged text:
        """
    }
    
    // MARK: - Heuristic Stitching
    
    private func stitchWithHeuristics(_ chunks: [String]) -> String {
        var result = chunks[0]
        
        for i in 1..<chunks.count {
            result = appendWithHeuristics(chunks[i], to: result)
        }
        
        return result
    }
    
    private func appendWithHeuristics(_ newChunk: String, to existingText: String) -> String {
        let existingWords = existingText.split(separator: " ").map(String.init)
        let newWords = newChunk.split(separator: " ").map(String.init)
        
        guard !existingWords.isEmpty && !newWords.isEmpty else {
            return existingText + (existingText.isEmpty ? "" : " ") + newChunk
        }
        
        // Find the best overlap point
        let overlapResult = findOverlap(existingWords: existingWords, newWords: newWords)
        
        if let overlap = overlapResult {
            // Remove overlapping portion from new chunk and append
            let nonOverlappingNew = Array(newWords.dropFirst(overlap.newStartIndex))
            if nonOverlappingNew.isEmpty {
                return existingText // New chunk was entirely duplicate
            }
            return existingText + " " + nonOverlappingNew.joined(separator: " ")
        } else {
            // No significant overlap found, just append with space
            return existingText + " " + newChunk
        }
    }
    
    // MARK: - Overlap Detection
    
    private struct OverlapResult {
        let existingEndIndex: Int
        let newStartIndex: Int
        let matchLength: Int
    }
    
    /// Find overlap between end of existing text and start of new text
    private func findOverlap(existingWords: [String], newWords: [String]) -> OverlapResult? {
        let maxOverlap = min(overlapWindowSize, existingWords.count, newWords.count)
        
        var bestMatch: OverlapResult?
        var bestMatchScore: Double = 0
        
        // Try different overlap lengths
        for overlapLen in (2...maxOverlap).reversed() {
            let existingEnd = Array(existingWords.suffix(overlapLen))
            let newStart = Array(newWords.prefix(overlapLen))
            
            let similarity = calculateSimilarity(existingEnd, newStart)
            
            if similarity >= duplicateSimilarityThreshold && similarity > bestMatchScore {
                bestMatch = OverlapResult(
                    existingEndIndex: existingWords.count - overlapLen,
                    newStartIndex: overlapLen,
                    matchLength: overlapLen
                )
                bestMatchScore = similarity
            }
        }
        
        return bestMatch
    }
    
    /// Calculate similarity between two word arrays (0.0-1.0)
    private func calculateSimilarity(_ words1: [String], _ words2: [String]) -> Double {
        guard words1.count == words2.count && !words1.isEmpty else { return 0 }
        
        var matches = 0
        for (w1, w2) in zip(words1, words2) {
            // Case-insensitive comparison, also handle punctuation
            let clean1 = w1.lowercased().trimmingCharacters(in: .punctuationCharacters)
            let clean2 = w2.lowercased().trimmingCharacters(in: .punctuationCharacters)
            
            if clean1 == clean2 {
                matches += 1
            } else if levenshteinSimilarity(clean1, clean2) > 0.8 {
                // Allow small typos/transcription errors
                matches += 1
            }
        }
        
        return Double(matches) / Double(words1.count)
    }
    
    /// Calculate Levenshtein similarity (1.0 = identical, 0.0 = completely different)
    private func levenshteinSimilarity(_ s1: String, _ s2: String) -> Double {
        let distance = levenshteinDistance(s1, s2)
        let maxLen = max(s1.count, s2.count)
        guard maxLen > 0 else { return 1.0 }
        return 1.0 - (Double(distance) / Double(maxLen))
    }
    
    /// Calculate Levenshtein edit distance
    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let s1Array = Array(s1)
        let s2Array = Array(s2)
        let len1 = s1Array.count
        let len2 = s2Array.count
        
        if len1 == 0 { return len2 }
        if len2 == 0 { return len1 }
        
        var matrix = Array(repeating: Array(repeating: 0, count: len2 + 1), count: len1 + 1)
        
        for i in 0...len1 { matrix[i][0] = i }
        for j in 0...len2 { matrix[0][j] = j }
        
        for i in 1...len1 {
            for j in 1...len2 {
                let cost = s1Array[i - 1] == s2Array[j - 1] ? 0 : 1
                matrix[i][j] = min(
                    matrix[i - 1][j] + 1,      // deletion
                    matrix[i][j - 1] + 1,      // insertion
                    matrix[i - 1][j - 1] + cost // substitution
                )
            }
        }
        
        return matrix[len1][len2]
    }
}

// MARK: - Convenience Extension

extension LLMStitchingService {
    /// Process transcript segments and return stitched blocks
    /// This is a higher-level method that works with TranscriptProcessor
    func processSegments(_ segments: [TranscriptionService.TranscriptSegment]) async -> [TranscriptBlock] {
        // Group consecutive segments by speaker
        var blocks: [TranscriptBlock] = []
        var currentSpeaker: TranscriptionService.TranscriptSegment.Speaker?
        var currentTexts: [String] = []
        var currentStartTime: TimeInterval = 0
        var currentEndTime: TimeInterval = 0
        
        for segment in segments {
            if segment.speaker != currentSpeaker && !currentTexts.isEmpty {
                // Speaker changed - finalize current block
                let stitchedText = await stitchChunks(currentTexts)
                if !stitchedText.isEmpty {
                    let speaker = TranscriptBlock.Speaker(from: currentSpeaker!)
                    blocks.append(TranscriptBlock(
                        speaker: speaker,
                        text: stitchedText,
                        startTimestamp: currentStartTime,
                        endTimestamp: currentEndTime
                    ))
                }
                currentTexts = []
            }
            
            if currentTexts.isEmpty {
                currentSpeaker = segment.speaker
                currentStartTime = segment.timestamp
            }
            
            currentTexts.append(segment.text)
            currentEndTime = segment.timestamp
        }
        
        // Finalize last block
        if !currentTexts.isEmpty, let speaker = currentSpeaker {
            let stitchedText = await stitchChunks(currentTexts)
            if !stitchedText.isEmpty {
                let blockSpeaker = TranscriptBlock.Speaker(from: speaker)
                blocks.append(TranscriptBlock(
                    speaker: blockSpeaker,
                    text: stitchedText,
                    startTimestamp: currentStartTime,
                    endTimestamp: currentEndTime
                ))
            }
        }
        
        return blocks
    }
}
