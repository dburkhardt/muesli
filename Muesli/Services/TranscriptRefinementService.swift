import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Service for refining transcripts using LLM
/// Cleans up transcripts, fixes grammar, improves flow
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
    
    // MARK: - Initialization
    
    init(llmManager: LLMManager) {
        self.llmManager = llmManager
    }
    
    // MARK: - Public Methods
    
    /// Refine transcript blocks using LLM
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
        
        // Refine each block individually to maintain speaker labels and timestamps
        var refinedBlocks: [TranscriptBlock] = []
        
        for (index, block) in blocks.enumerated() {
            progress = Double(index) / Double(blocks.count)
            
            let refinedText = try await refineBlockText(block.text, container: container)
            
            var refinedBlock = block
            refinedBlock.text = refinedText
            refinedBlocks.append(refinedBlock)
        }
        
        progress = 1.0
        return refinedBlocks
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
    
    // MARK: - Private Methods
    
    private func refineBlockText(_ text: String, container: ModelContainer) async throws -> String {
        let prompt = buildRefinementPrompt(text)
        
        let result = try await container.perform { context in
            // Prepare input messages
            let messages: [Chat.Message] = [
                .system("You are a transcript editor. Your job is to clean up transcriptions by fixing grammar, removing filler words (um, uh, like), improving sentence flow, and making the text more readable. Do not change the meaning or add information. Output only the cleaned text, nothing else."),
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
    
    private func buildRefinementPrompt(_ text: String) -> String {
        """
        Clean up this transcript by fixing grammar, removing filler words, and improving readability. Do not change the meaning or add information:
        
        \(text)
        
        Cleaned transcript:
        """
    }
}
