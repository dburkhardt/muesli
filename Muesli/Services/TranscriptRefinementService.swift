import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Service for post-meeting transcript refinement using local LLMs
/// Cleans up transcripts by fixing spelling, punctuation, and formatting
///
/// Unlike LLMStitchingService (real-time), this runs on completed transcripts
@MainActor
final class TranscriptRefinementService {
    
    // MARK: - Dependencies
    
    private let llmManager: LLMManager
    
    // MARK: - State
    
    /// Current refinement progress (0.0-1.0)
    var progress: Double = 0
    
    /// Whether refinement is in progress
    var isRefining: Bool = false
    
    /// Error message if refinement failed
    var errorMessage: String?
    
    // MARK: - Configuration
    
    /// Maximum tokens per refinement chunk
    private let maxChunkTokens: Int = 1500
    
    /// Maximum tokens to generate per response
    private let maxGenerationTokens: Int = 2000
    
    // MARK: - Initialization
    
    init(llmManager: LLMManager) {
        self.llmManager = llmManager
    }
    
    // MARK: - Public Methods
    
    /// Check if refinement is available (model downloaded and loaded)
    var canRefine: Bool {
        llmManager.isLLMAvailable
    }
    
    /// Refine a complete transcript
    /// - Parameter blocks: The transcript blocks to refine
    /// - Returns: Refined transcript blocks
    func refineTranscript(_ blocks: [TranscriptBlock]) async throws -> [TranscriptBlock] {
        guard canRefine else {
            throw RefinementError.modelNotAvailable
        }
        
        isRefining = true
        progress = 0
        errorMessage = nil
        
        defer {
            isRefining = false
        }
        
        do {
            // Process blocks in batches to stay within context limits
            var refinedBlocks: [TranscriptBlock] = []
            let totalBlocks = blocks.count
            
            for (index, block) in blocks.enumerated() {
                let refinedText = try await refineText(block.text)
                
                var refinedBlock = block
                refinedBlock.text = refinedText
                refinedBlocks.append(refinedBlock)
                
                progress = Double(index + 1) / Double(totalBlocks)
            }
            
            return refinedBlocks
            
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }
    
    /// Refine plain text transcript
    /// - Parameter text: The transcript text to refine
    /// - Returns: Refined transcript text
    func refineTranscript(_ text: String) async throws -> String {
        guard canRefine else {
            throw RefinementError.modelNotAvailable
        }
        
        isRefining = true
        progress = 0
        errorMessage = nil
        
        defer {
            isRefining = false
        }
        
        do {
            // Split into manageable chunks if needed
            let chunks = splitIntoChunks(text)
            var refinedChunks: [String] = []
            
            for (index, chunk) in chunks.enumerated() {
                let refinedChunk = try await refineText(chunk)
                refinedChunks.append(refinedChunk)
                progress = Double(index + 1) / Double(chunks.count)
            }
            
            return refinedChunks.joined(separator: "\n\n")
            
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }
    
    // MARK: - Private Methods
    
    private func refineText(_ text: String) async throws -> String {
        guard let container = llmManager.modelContainer else {
            throw RefinementError.modelNotLoaded
        }
        
        let prompt = buildRefinementPrompt(text)
        let sysPrompt = systemPrompt  // Capture on main actor before entering closure
        let maxTokens = maxGenerationTokens
        
        let result = try await container.perform { context in
            let messages: [Chat.Message] = [
                .system(sysPrompt),
                .user(prompt)
            ]
            
            let userInput = UserInput(chat: messages)
            let input = try await context.processor.prepare(input: userInput)
            
            let generateParams = GenerateParameters(
                maxTokens: maxTokens,
                temperature: 0.1  // Low temperature for consistent output
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
        
        let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Validate output - if suspiciously different, return original
        if cleaned.isEmpty || cleaned.count < text.count / 3 {
            return text
        }
        
        return cleaned
    }
    
    private var systemPrompt: String {
        """
        You are a transcript editor. Your job is to clean up meeting transcripts while preserving the original meaning and speaker attributions.
        
        Fix the following issues:
        - Spelling errors and homophones (e.g., "their/there/they're", "your/you're")
        - Punctuation and sentence boundaries
        - Capitalization of proper nouns and sentence starts
        - Repeated words or phrases from audio processing artifacts
        - Minor grammar issues that don't change meaning
        
        Do NOT:
        - Add new content or paraphrase
        - Remove or significantly restructure content
        - Change technical terms or names you're unsure about
        - Add formatting like headers or bullet points
        
        Output only the cleaned transcript text, nothing else.
        """
    }
    
    private func buildRefinementPrompt(_ text: String) -> String {
        """
        Clean up this transcript:
        
        \(text)
        
        Cleaned transcript:
        """
    }
    
    /// Split text into chunks that fit within context window
    private func splitIntoChunks(_ text: String) -> [String] {
        let words = text.split(separator: " ")
        let wordsPerChunk = maxChunkTokens / 2  // Rough estimate: ~2 chars per token
        
        if words.count <= wordsPerChunk {
            return [text]
        }
        
        var chunks: [String] = []
        var currentChunk: [Substring] = []
        
        for word in words {
            currentChunk.append(word)
            
            if currentChunk.count >= wordsPerChunk {
                chunks.append(currentChunk.joined(separator: " "))
                currentChunk = []
            }
        }
        
        if !currentChunk.isEmpty {
            chunks.append(currentChunk.joined(separator: " "))
        }
        
        return chunks
    }
    
    // MARK: - Errors
    
    enum RefinementError: LocalizedError {
        case modelNotAvailable
        case modelNotLoaded
        case refinementFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .modelNotAvailable:
                return "No LLM model is available. Please download a model in Preferences."
            case .modelNotLoaded:
                return "LLM model is not loaded. Please try again."
            case .refinementFailed(let message):
                return "Refinement failed: \(message)"
            }
        }
    }
}
