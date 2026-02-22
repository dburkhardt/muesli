@testable import Muesli
import XCTest

@MainActor
final class AINotesSummaryServiceTests: XCTestCase {
    func testSummarize_ThrowsWhenNoActiveModel() async {
        let llmManager = LLMManager(skipHubAccess: true)
        let service = AINotesSummaryService(llmManager: llmManager)
        
        do {
            _ = try await service.summarize(
                transcript: "Test transcript",
                userPrompt: PreferencesManager.defaultAISummaryPrompt
            )
            XCTFail("Expected summarize to throw without an active model")
        } catch let error as AINotesSummaryService.SummaryError {
            if case .modelNotSelected = error {
                XCTAssertTrue(true)
            } else {
                XCTFail("Expected modelNotSelected, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
    func testSummarize_ThrowsWhenModelSelectedButNotLoaded() async {
        let llmManager = LLMManager(skipHubAccess: true)
        llmManager.activeModel = .qwen3_1_7b
        let service = AINotesSummaryService(llmManager: llmManager)
        
        do {
            _ = try await service.summarize(
                transcript: "Test transcript",
                userPrompt: PreferencesManager.defaultAISummaryPrompt
            )
            XCTFail("Expected summarize to throw when model container is missing")
        } catch let error as AINotesSummaryService.SummaryError {
            if case .modelNotLoaded = error {
                XCTAssertTrue(true)
            } else {
                XCTFail("Expected modelNotLoaded, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
    func testSummarize_UsesSingleChunkPathAndSanitizesOutput() async throws {
        let llmManager = LLMManager(skipHubAccess: true)
        let service = AINotesSummaryService(
            llmManager: llmManager,
            testGenerationOverride: { _ in
                """
                ```markdown
                Final notes
                ```
                """
            },
            bypassModelAvailabilityChecks: true
        )
        
        let output = try await service.summarize(
            transcript: "Short transcript block",
            userPrompt: "Summarize this"
        )
        
        XCTAssertEqual(output, "Final notes")
    }
    
    func testSummarize_UsesChunkMergePathForLongTranscript() async throws {
        let llmManager = LLMManager(skipHubAccess: true)
        var prompts: [String] = []
        let service = AINotesSummaryService(
            llmManager: llmManager,
            testGenerationOverride: { prompt in
                prompts.append(prompt)
                return "summary-\(prompts.count)"
            },
            bypassModelAvailabilityChecks: true
        )
        
        let longTranscript = Array(repeating: String(repeating: "x", count: 2200), count: 4).joined(separator: "\n\n")
        let output = try await service.summarize(transcript: longTranscript, userPrompt: "Summarize")
        
        XCTAssertEqual(output, "summary-\(prompts.count)")
        XCTAssertGreaterThanOrEqual(prompts.count, 3) // at least chunk summaries + merge pass
    }
    
    func testSummarize_ThrowsForMetaOnlyResponse() async {
        let llmManager = LLMManager(skipHubAccess: true)
        let service = AINotesSummaryService(
            llmManager: llmManager,
            testGenerationOverride: { _ in "I cannot summarize this" },
            bypassModelAvailabilityChecks: true
        )
        
        do {
            _ = try await service.summarize(transcript: "Transcript", userPrompt: "Prompt")
            XCTFail("Expected emptyResponse for meta-only output")
        } catch let error as AINotesSummaryService.SummaryError {
            if case .emptyResponse = error {
                XCTAssertTrue(true)
            } else {
                XCTFail("Expected emptyResponse, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
    func testSummarize_ThrowsGenerationFailedWhenOverrideThrows() async {
        enum TestError: Error { case failed }
        
        let llmManager = LLMManager(skipHubAccess: true)
        let service = AINotesSummaryService(
            llmManager: llmManager,
            testGenerationOverride: { _ in throw TestError.failed },
            bypassModelAvailabilityChecks: true
        )
        
        do {
            _ = try await service.summarize(transcript: "Transcript", userPrompt: "Prompt")
            XCTFail("Expected generationFailed error")
        } catch let error as AINotesSummaryService.SummaryError {
            if case .generationFailed = error {
                XCTAssertTrue(true)
            } else {
                XCTFail("Expected generationFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
    func testSummarize_ThrowsEmptyResponseForBlankTranscript() async {
        let llmManager = LLMManager(skipHubAccess: true)
        let service = AINotesSummaryService(
            llmManager: llmManager,
            testGenerationOverride: { _ in "should not run" },
            bypassModelAvailabilityChecks: true
        )
        
        do {
            _ = try await service.summarize(transcript: "   ", userPrompt: "Prompt")
            XCTFail("Expected emptyResponse for blank transcript")
        } catch let error as AINotesSummaryService.SummaryError {
            if case .emptyResponse = error {
                XCTAssertTrue(true)
            } else {
                XCTFail("Expected emptyResponse, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
    func testChunkTranscript_SplitsByBlocksAndHardLimit() {
        let block1 = String(repeating: "a", count: 8)
        let block2 = String(repeating: "b", count: 8)
        let longBlock = String(repeating: "c", count: 25)
        let transcript = "\(block1)\n\n\(block2)\n\n\(longBlock)"
        
        let chunks = AINotesSummaryTextProcessor.chunkTranscript(transcript, chunkCharacterLimit: 10)
        
        XCTAssertGreaterThan(chunks.count, 2)
        XCTAssertEqual(chunks[0], block1)
        XCTAssertEqual(chunks[1], block2)
        XCTAssertTrue(chunks.dropFirst(2).allSatisfy { $0.count <= 10 })
    }
    
    func testHardSplit_SplitsIntoFixedWindows() {
        let text = String(repeating: "z", count: 25)
        let parts = AINotesSummaryTextProcessor.hardSplit(text, limit: 10)
        
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0].count, 10)
        XCTAssertEqual(parts[1].count, 10)
        XCTAssertEqual(parts[2].count, 5)
    }
    
    func testSanitizeOutput_StripsMarkdownCodeFences() {
        let fenced = """
        ```markdown
        - item 1
        - item 2
        ```
        """
        
        let sanitized = AINotesSummaryTextProcessor.sanitizeOutput(fenced)
        
        XCTAssertEqual(sanitized, "- item 1\n- item 2")
    }
    
    func testIsMetaOnly_DetectsRefusalPhrases() {
        XCTAssertTrue(AINotesSummaryTextProcessor.isMetaOnly("No transcript provided"))
        XCTAssertTrue(AINotesSummaryTextProcessor.isMetaOnly("I cannot summarize this"))
        XCTAssertTrue(AINotesSummaryTextProcessor.isMetaOnly("I'm unable to help with that"))
        XCTAssertFalse(AINotesSummaryTextProcessor.isMetaOnly("Decisions:\n- Launch Friday"))
    }
}
