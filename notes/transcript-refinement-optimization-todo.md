# Transcript Refinement Optimization - Next Steps

**Branch**: `resume-recording-feature`  
**Last Updated**: 2025-01-17  
**Status**: Not started - ready for implementation

## Background

The current `TranscriptRefinementService.swift` processes transcript blocks one-by-one, making a separate LLM call for each block (~75 words). This results in:
- ~90-150 seconds to refine a 10-minute meeting
- High overhead from repeated LLM context loading
- Poor efficiency for the local LLM

## Planned Optimization

Implement **speaker-threaded batch processing**:
1. Separate transcript into "Me" (microphone) and "Them" (system audio) threads
2. Batch multiple blocks within each thread (up to 4000 characters per batch)
3. Refine each speaker thread independently
4. Merge results back chronologically

**Expected improvement**: 5-10x faster (18-30 seconds instead of 90-150 seconds)

## Implementation Tasks

### 1. Add Batch Configuration Constant
**File**: `Muesli/Services/TranscriptRefinementService.swift`

Add after the existing `maxGenerationTokens` constant:
```swift
/// Maximum characters to refine in a single batch (~1000 tokens input)
private let maxBatchCharacters: Int = 4000
```

### 2. Add `splitBlocksBySpeaker()` Helper
**File**: `Muesli/Services/TranscriptRefinementService.swift`

```swift
/// Splits blocks into separate speaker threads while preserving original indices
private func splitBlocksBySpeaker(_ blocks: [TranscriptBlock]) -> (me: [(Int, TranscriptBlock)], them: [(Int, TranscriptBlock)]) {
    var meBlocks: [(Int, TranscriptBlock)] = []
    var themBlocks: [(Int, TranscriptBlock)] = []
    
    for (index, block) in blocks.enumerated() {
        if block.speaker == "Me" {
            meBlocks.append((index, block))
        } else {
            themBlocks.append((index, block))
        }
    }
    
    return (meBlocks, themBlocks)
}
```

### 3. Add `refineSpeakerThread()` Method
**File**: `Muesli/Services/TranscriptRefinementService.swift`

This method should:
- Take an array of `(Int, TranscriptBlock)` tuples (index + block)
- Batch consecutive blocks until `maxBatchCharacters` is reached
- Call the LLM once per batch with appropriate prompt
- Split refined text back to individual blocks
- Report progress updates
- Return array of `(Int, TranscriptBlock)` with refined text

### 4. Add `splitRefinedText()` Method
**File**: `Muesli/Services/TranscriptRefinementService.swift`

```swift
/// Splits refined text back into blocks based on original block structure
private func splitRefinedText(_ refinedText: String, originalBlocks: [TranscriptBlock]) -> [TranscriptBlock] {
    // Use original word counts as guides for splitting
    // Handle edge cases where LLM output differs from expected
    // Preserve timestamps from original blocks
}
```

### 5. Refactor `refineTranscript(_ blocks:)` Method
**File**: `Muesli/Services/TranscriptRefinementService.swift`

Replace the current sequential per-block implementation with:
```swift
func refineTranscript(_ blocks: [TranscriptBlock]) async throws -> [TranscriptBlock] {
    guard let container = await llmManager.modelContainer else {
        throw NSError(domain: "TranscriptRefinement", code: 1, 
                      userInfo: [NSLocalizedDescriptionKey: "LLM not loaded"])
    }
    
    // Split by speaker
    let (meBlocks, themBlocks) = splitBlocksBySpeaker(blocks)
    
    // Refine "Me" thread (progress 0.0 - 0.5)
    let refinedMe = try await refineSpeakerThread(
        meBlocks, 
        speaker: "Me",
        container: container,
        progressRange: (0.0, 0.5)
    )
    
    // Refine "Them" thread (progress 0.5 - 1.0)
    let refinedThem = try await refineSpeakerThread(
        themBlocks,
        speaker: "Them", 
        container: container,
        progressRange: (0.5, 1.0)
    )
    
    // Merge back chronologically by original index
    var result = Array(repeating: blocks[0], count: blocks.count)
    for (index, block) in refinedMe {
        result[index] = block
    }
    for (index, block) in refinedThem {
        result[index] = block
    }
    
    return result
}
```

### 6. Update `buildRefinementPrompt()` for Speaker Context
**File**: `Muesli/Services/TranscriptRefinementService.swift`

Add speaker parameter and customize prompts:
- For "Me": Focus on first-person corrections, filler word removal
- For "Them": Focus on speaker detection hints, third-person corrections

## Reference Plan File

The detailed plan with rationale is at:
`/Users/dburkhardt/.cursor/plans/optimize_transcript_refinement_with_speaker_threads_8d714c91.plan.md`

## Testing

After implementation:
1. Test with short meeting (1-2 minutes) - verify correctness
2. Test with longer meeting (10+ minutes) - verify performance improvement
3. Test with single speaker only (just microphone or just system audio)
4. Test with rapid back-and-forth conversation

## Files to Modify

- `Muesli/Services/TranscriptRefinementService.swift` - Main implementation file

## Related Files (for context)

- `Muesli/Services/LLMStitchingService.swift` - Similar pattern for LLM calls
- `Muesli/Models/TranscriptBlock.swift` - Data model being processed
- `Muesli/ViewModels/MuesliViewModel.swift` - Calls `refineTranscript()`
