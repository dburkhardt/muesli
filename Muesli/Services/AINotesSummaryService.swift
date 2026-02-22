import Foundation
import MLX
import MLXLLM
import MLXLMCommon

enum AINotesSummaryTextProcessor {
    static func chunkTranscript(_ transcript: String, chunkCharacterLimit: Int) -> [String] {
        guard transcript.count > chunkCharacterLimit else {
            return [transcript]
        }
        
        var chunks: [String] = []
        var currentChunk = ""
        
        for block in transcript.components(separatedBy: "\n\n") {
            let candidate = currentChunk.isEmpty ? block : "\(currentChunk)\n\n\(block)"
            if candidate.count > chunkCharacterLimit, !currentChunk.isEmpty {
                chunks.append(currentChunk)
                if block.count > chunkCharacterLimit {
                    chunks.append(contentsOf: hardSplit(block, limit: chunkCharacterLimit))
                    currentChunk = ""
                } else {
                    currentChunk = block
                }
            } else {
                currentChunk = candidate
            }
        }
        
        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }
        return chunks
    }
    
    static func hardSplit(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var parts: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
            parts.append(String(text[start..<end]))
            start = end
        }
        return parts
    }
    
    static func sanitizeOutput(_ output: String) -> String {
        var cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.replacingOccurrences(of: #"^```[a-zA-Z]*\n"#, with: "", options: .regularExpression)
            cleaned = cleaned.replacingOccurrences(of: #"\n```$"#, with: "", options: .regularExpression)
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }
    
    static func isMetaOnly(_ output: String) -> Bool {
        let lowered = output.lowercased()
        return lowered == "no transcript provided"
            || lowered == "i cannot summarize this"
            || lowered.hasPrefix("i cannot")
            || lowered.hasPrefix("i'm unable")
    }
}

@MainActor
protocol AINotesSummaryGenerating: AnyObject {
    func summarize(transcript: String, userPrompt: String) async throws -> String
}

/// Generates concise AI notes from meeting transcripts using the local LLM model container.
@MainActor
final class AINotesSummaryService: AINotesSummaryGenerating {
    enum SummaryError: LocalizedError {
        case modelNotLoaded
        case modelNotSelected
        case generationFailed(String)
        case emptyResponse
        
        var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "LLM model is not loaded"
            case .modelNotSelected:
                return "No active LLM model selected"
            case .generationFailed(let reason):
                return "Summary generation failed: \(reason)"
            case .emptyResponse:
                return "Summary output was empty"
            }
        }
    }
    
    private let llmManager: LLMManager
    private let maxOutputTokens = 900
    private let chunkCharacterLimit = 6000
    private let testGenerationOverride: ((String) async throws -> String)?
    private let bypassModelAvailabilityChecks: Bool
    
    init(
        llmManager: LLMManager,
        testGenerationOverride: ((String) async throws -> String)? = nil,
        bypassModelAvailabilityChecks: Bool = false
    ) {
        self.llmManager = llmManager
        self.testGenerationOverride = testGenerationOverride
        self.bypassModelAvailabilityChecks = bypassModelAvailabilityChecks
    }
    
    func summarize(transcript: String, userPrompt: String) async throws -> String {
        let container: ModelContainer?
        if !bypassModelAvailabilityChecks && testGenerationOverride == nil {
            guard llmManager.activeModel != nil else {
                throw SummaryError.modelNotSelected
            }
            guard let loadedContainer = llmManager.modelContainer else {
                throw SummaryError.modelNotLoaded
            }
            container = loadedContainer
        } else {
            container = llmManager.modelContainer
        }
        
        let cleanedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTranscript.isEmpty else {
            throw SummaryError.emptyResponse
        }
        
        let chunks = AINotesSummaryTextProcessor.chunkTranscript(
            cleanedTranscript,
            chunkCharacterLimit: chunkCharacterLimit
        )
        let basePrompt = PreferencesManager.normalizeAISummaryPrompt(userPrompt)
        
        let output: String
        if chunks.count == 1 {
            output = try await summarizeSingleChunk(
                transcriptChunk: chunks[0],
                userPrompt: basePrompt,
                container: container
            )
        } else {
            output = try await summarizeMultiChunk(
                chunks: chunks,
                userPrompt: basePrompt,
                container: container
            )
        }
        
        let cleanedOutput = AINotesSummaryTextProcessor.sanitizeOutput(output)
        guard !cleanedOutput.isEmpty, !AINotesSummaryTextProcessor.isMetaOnly(cleanedOutput) else {
            throw SummaryError.emptyResponse
        }
        return cleanedOutput
    }
    
    private func summarizeSingleChunk(
        transcriptChunk: String,
        userPrompt: String,
        container: ModelContainer?
    ) async throws -> String {
        let prompt = """
        \(userPrompt)
        
        Transcript:
        \(transcriptChunk)
        """
        return try await runGeneration(prompt: prompt, container: container)
    }
    
    private func summarizeMultiChunk(
        chunks: [String],
        userPrompt: String,
        container: ModelContainer?
    ) async throws -> String {
        var partialSummaries: [String] = []
        
        for (index, chunk) in chunks.enumerated() {
            let chunkPrompt = """
            \(userPrompt)
            
            This is chunk \(index + 1) of \(chunks.count). Summarize only this chunk while preserving facts.
            
            Transcript chunk:
            \(chunk)
            """
            let partial = try await runGeneration(prompt: chunkPrompt, container: container)
            partialSummaries.append(AINotesSummaryTextProcessor.sanitizeOutput(partial))
        }
        
        let mergePrompt = """
        \(userPrompt)
        
        Merge these chunk summaries into one coherent final AI note. Remove duplication, preserve key decisions and action items.
        
        Chunk summaries:
        \(partialSummaries.enumerated().map { "Chunk \($0.offset + 1):\n\($0.element)" }.joined(separator: "\n\n"))
        """
        
        return try await runGeneration(prompt: mergePrompt, container: container)
    }
    
    private func runGeneration(prompt: String, container: ModelContainer?) async throws -> String {
        do {
            if let testGenerationOverride {
                let output = try await testGenerationOverride(prompt)
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw SummaryError.emptyResponse }
                return trimmed
            }
            
            guard let container else {
                throw SummaryError.modelNotLoaded
            }
            
            let response = try await container.perform { context in
                let system = """
                You are a meeting notes assistant.
                Produce concise, factual AI notes from transcript input.
                Do not invent facts, names, decisions, or action items.
                Return only the final notes content.
                """
                let messages: [Chat.Message] = [
                    .system(system),
                    .user(prompt)
                ]
                let input = try await context.processor.prepare(input: UserInput(chat: messages))
                let params = GenerateParameters(maxTokens: self.maxOutputTokens, temperature: 0.15)
                let cache = context.model.newCache(parameters: params)
                let iterator = try TokenIterator(
                    input: input,
                    model: context.model,
                    cache: cache,
                    parameters: params
                )
                let result: GenerateResult = generate(
                    input: input,
                    context: context,
                    iterator: iterator
                ) { _ in .more }
                Stream.gpu.synchronize()
                return result.output
            }
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw SummaryError.emptyResponse }
            return trimmed
        } catch let error as SummaryError {
            throw error
        } catch {
            throw SummaryError.generationFailed(error.localizedDescription)
        }
    }
    
}
