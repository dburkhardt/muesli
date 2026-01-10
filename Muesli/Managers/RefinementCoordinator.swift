import Foundation

/// Coordinates transcript refinement using LLM
/// Extracted from MuesliViewModel as part of the god object refactoring
@Observable
@MainActor
final class RefinementCoordinator {
    
    // MARK: - Dependencies
    
    private let llmManager: LLMManager
    private let refinementService: TranscriptRefinementService
    private let fileOutputService: FileOutputService
    
    // MARK: - State
    
    /// Whether to show the refinement progress sheet
    var showRefineSheet: Bool = false
    
    /// Whether to show the post-meeting refinement prompt
    var showRefinementPrompt: Bool = false
    
    /// Meeting being refined (for UI state)
    var meetingBeingRefined: MeetingHistoryItem?
    
    /// Cancellation flag for refinement
    private var refinementCancelled: Bool = false
    
    /// Per-meeting state: whether to show original transcript (vs refined)
    /// Key is meeting ID UUID string
    private var showOriginalTranscriptForMeeting: [String: Bool] = [:]
    
    // MARK: - Computed Properties
    
    /// Check if refinement is available (LLM model downloaded)
    var canRefineTranscripts: Bool {
        llmManager.hasModel && llmManager.isLLMStitchingEnabled
    }
    
    /// Whether refinement is currently in progress
    var isRefining: Bool {
        refinementService.isRefining
    }
    
    /// Current refinement progress (0.0 to 1.0)
    var refinementProgress: Double {
        refinementService.progress
    }
    
    /// Refinement error message if any
    var errorMessage: String? {
        refinementService.errorMessage
    }
    
    // MARK: - Initialization
    
    init(llmManager: LLMManager, fileOutputService: FileOutputService = FileOutputService()) {
        self.llmManager = llmManager
        self.refinementService = TranscriptRefinementService(llmManager: llmManager)
        self.fileOutputService = fileOutputService
    }
    
    // MARK: - Show Original/Refined Toggle
    
    /// Get whether to show original transcript for a meeting
    func isShowingOriginal(for meeting: MeetingHistoryItem) -> Bool {
        showOriginalTranscriptForMeeting[meeting.id.uuidString] ?? false
    }
    
    /// Set whether to show original transcript for a meeting
    func setShowingOriginal(_ showOriginal: Bool, for meeting: MeetingHistoryItem, historyService: MeetingHistoryService) {
        showOriginalTranscriptForMeeting[meeting.id.uuidString] = showOriginal
        
        // Load original transcript if switching to original view and not already loaded
        if showOriginal && meeting.isRefined {
            Task {
                if meeting.originalTranscriptBlocks == nil, let blocks = historyService.loadOriginalTranscriptBlocks(for: meeting) {
                    await MainActor.run {
                        meeting.originalTranscriptBlocks = blocks
                    }
                }
                if meeting.originalTranscript == nil, let text = historyService.loadOriginalTranscript(for: meeting) {
                    await MainActor.run {
                        meeting.originalTranscript = text
                    }
                }
            }
        }
    }
    
    // MARK: - Refinement Actions
    
    /// Start refining a meeting's transcript
    func refineTranscript(for meeting: MeetingHistoryItem) {
        guard canRefineTranscripts else {
            print("[RefinementCoordinator] Cannot refine: canRefineTranscripts = false")
            return
        }
        guard !refinementService.isRefining else {
            print("[RefinementCoordinator] Already refining")
            return
        }
        
        meetingBeingRefined = meeting
        refinementCancelled = false
        
        Task {
            await refineTranscriptAsync(for: meeting)
        }
    }
    
    /// Async refinement implementation
    private func refineTranscriptAsync(for meeting: MeetingHistoryItem) async {
        // Ensure model is loaded
        if llmManager.modelContainer == nil, let activeModel = llmManager.activeModel {
            do {
                try await llmManager.loadModel(activeModel)
            } catch {
                refinementService.errorMessage = "Failed to load LLM model: \(error.localizedDescription)"
                print("[RefinementCoordinator] Failed to load LLM model: \(error)")
                meetingBeingRefined = nil
                return
            }
        }
        
        do {
            // Refine based on available transcript format
            if let blocks = meeting.transcriptBlocks, !blocks.isEmpty {
                print("[RefinementCoordinator] Refining \(blocks.count) transcript blocks")
                // Store original before refining
                if meeting.originalTranscriptBlocks == nil {
                    meeting.originalTranscriptBlocks = blocks
                    meeting.originalTranscript = blocks.map { block in
                        "**\(block.speaker.rawValue.capitalized)** _[\(block.formattedStartTime)]_\n\n\(block.text)"
                    }.joined(separator: "\n\n")
                }
                
                // Refine block-based transcript
                let refinedBlocks = try await refinementService.refineTranscript(blocks)
                
                guard !refinementCancelled else { return }
                
                // Update meeting with refined blocks
                meeting.transcriptBlocks = refinedBlocks
                meeting.isRefined = true
                
                // Default to showing refined view
                showOriginalTranscriptForMeeting[meeting.id.uuidString] = false
                
                // Update plain text representation
                meeting.transcript = refinedBlocks.map { block in
                    "**\(block.speaker.rawValue.capitalized)** _[\(block.formattedStartTime)]_\n\n\(block.text)"
                }.joined(separator: "\n\n")
                
                // Save to disk
                saveRefinedTranscript(meeting, blocks: refinedBlocks)
                
            } else if let text = meeting.transcript, !text.isEmpty {
                print("[RefinementCoordinator] Refining plain text transcript")
                // Store original before refining
                meeting.originalTranscript = text
                
                // Refine plain text transcript
                let refinedText = try await refinementService.refineTranscript(text)
                
                guard !refinementCancelled else {
                    print("[RefinementCoordinator] Refinement cancelled")
                    meetingBeingRefined = nil
                    return
                }
                
                // Update meeting
                meeting.transcript = refinedText
                meeting.isRefined = true
                
                // Save to disk
                saveRefinedTranscript(meeting, text: refinedText)
                print("[RefinementCoordinator] Refinement completed successfully")
            } else {
                print("[RefinementCoordinator] No transcript blocks or text available for refinement")
                meetingBeingRefined = nil
                return
            }
            
            // Clear refinement state
            meetingBeingRefined = nil
            
        } catch {
            // Error is already set in refinementService
            print("[RefinementCoordinator] Refinement failed: \(error)")
            meetingBeingRefined = nil
        }
    }
    
    /// Cancel ongoing refinement
    func cancelRefinement() {
        refinementCancelled = true
        meetingBeingRefined = nil
    }
    
    // MARK: - Segment Refinement
    
    /// Refine a single transcript segment
    func refineSegment(_ segment: TranscriptSegment, in meeting: MeetingHistoryItem) async {
        guard canRefineTranscripts else { return }
        guard !segment.isRefined else { return }
        
        // Ensure model is loaded
        if llmManager.modelContainer == nil, let activeModel = llmManager.activeModel {
            do {
                try await llmManager.loadModel(activeModel)
            } catch {
                print("[RefinementCoordinator] Failed to load LLM model for segment refinement: \(error)")
                return
            }
        }
        
        do {
            // Refine the segment's blocks
            let refinedBlocks = try await refinementService.refineTranscript(segment.originalBlocks)
            
            // Update segment
            if let segmentIndex = meeting.transcriptSegments.firstIndex(where: { $0.id == segment.id }) {
                meeting.transcriptSegments[segmentIndex].refinedBlocks = refinedBlocks
                meeting.transcriptSegments[segmentIndex].isRefined = true
            }
            
            // Default to showing refined view after refinement completes
            meeting.isShowingRefined = true
            
            // Update meeting transcript display
            updateMeetingTranscriptDisplay(meeting)
            
        } catch {
            print("[RefinementCoordinator] Segment refinement failed: \(error)")
        }
    }
    
    /// Update meeting's display transcript from segments
    func updateMeetingTranscriptDisplay(_ meeting: MeetingHistoryItem) {
        var allBlocks: [TranscriptBlock] = []
        
        for segment in meeting.transcriptSegments.sorted(by: { $0.segmentNumber < $1.segmentNumber }) {
            // Use refined blocks if available and showing refined, otherwise use original
            let blocksToUse = (meeting.isShowingRefined && segment.isRefined) ?
                (segment.refinedBlocks ?? segment.originalBlocks) :
                segment.originalBlocks
            
            allBlocks.append(contentsOf: blocksToUse)
        }
        
        meeting.transcriptBlocks = allBlocks
        meeting.transcript = allBlocks.map { block in
            "**\(block.speaker.rawValue.capitalized)** _[\(block.formattedStartTime)]_\n\n\(block.text)"
        }.joined(separator: "\n\n")
    }
    
    /// Update segmented meeting transcript display with segment headers
    func updateSegmentedMeetingTranscriptDisplay(_ meeting: MeetingHistoryItem, with blocks: [TranscriptBlock], segmentNumber: Int, segmentStartTime: Date) {
        // Build transcript with segment headers
        var transcriptParts: [String] = []
        
        // Add existing segments
        for segment in meeting.transcriptSegments.sorted(by: { $0.segmentNumber < $1.segmentNumber }) {
            if segment.segmentNumber > 1 {
                let formatter = DateFormatter()
                formatter.dateFormat = "h:mm a"
                transcriptParts.append("\n---\n### Segment \(segment.segmentNumber) (resumed at \(formatter.string(from: segment.startTime)))\n")
            }
            
            // Use refined blocks if available and showing refined, otherwise use original
            let blocksToUse = (meeting.isShowingRefined && segment.isRefined) ?
                (segment.refinedBlocks ?? segment.originalBlocks) :
                segment.originalBlocks
            
            for block in blocksToUse {
                transcriptParts.append("**\(block.speaker.rawValue.capitalized)** _[\(block.formattedStartTime)]_\n\n\(block.text)")
            }
        }
        
        meeting.transcript = transcriptParts.joined(separator: "\n\n")
    }
    
    // MARK: - File Saving
    
    /// Save refined block-based transcript to disk
    private func saveRefinedTranscript(_ meeting: MeetingHistoryItem, blocks: [TranscriptBlock]) {
        do {
            // Save original transcript to separate file if it exists
            if let originalBlocks = meeting.originalTranscriptBlocks {
                let originalURL = meeting.directory.appendingPathComponent("transcript.original.md")
                try fileOutputService.saveTranscriptBlocks(
                    originalBlocks,
                    title: meeting.title,
                    date: meeting.date,
                    to: originalURL
                )
            }
            
            // Save refined transcript
            try fileOutputService.saveTranscriptBlocks(
                blocks,
                title: meeting.title,
                date: meeting.date,
                to: meeting.directory
            )
        } catch {
            print("[RefinementCoordinator] Failed to save refined transcript: \(error)")
        }
    }
    
    /// Save refined plain text transcript to disk
    private func saveRefinedTranscript(_ meeting: MeetingHistoryItem, text: String) {
        do {
            // Save original transcript to separate file if it exists
            if let originalText = meeting.originalTranscript {
                let originalURL = meeting.directory.appendingPathComponent("transcript.original.md")
                let originalContent = """
                # \(meeting.title)
                \(formatDate(meeting.date))
                
                ## Transcript
                
                \(originalText)
                """
                try originalContent.write(to: originalURL, atomically: true, encoding: .utf8)
            }
            
            // Save refined transcript
            let transcriptURL = meeting.directory.appendingPathComponent("transcript.md")
            let content = """
            # \(meeting.title)
            \(formatDate(meeting.date))
            
            ## Transcript
            
            \(text)
            """
            try content.write(to: transcriptURL, atomically: true, encoding: .utf8)
        } catch {
            print("[RefinementCoordinator] Failed to save refined transcript: \(error)")
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
