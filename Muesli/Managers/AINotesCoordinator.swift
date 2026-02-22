import Foundation
import os.log

actor AINotesGenerationGate {
    private var isBusy = false
    
    func acquire() async throws {
        while isBusy {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        isBusy = true
    }
    
    func release() {
        isBusy = false
    }
}

@MainActor
final class AINotesCoordinator {
    struct GenerationState: Codable {
        let sourceFingerprint: String
        let summaryFingerprint: String
    }
    
    private let logger = Logger(subsystem: "com.muesli.app", category: "AINotesCoordinator")
    private let llmManager: LLMManager
    private let summaryService: AINotesSummaryGenerating
    private let refinementCoordinator: RefinementCoordinator
    private let generationGate: AINotesGenerationGate
    
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var lastStartAt: [UUID: Date] = [:]
    private var lastSourceFingerprint: [UUID: String] = [:]
    
    var onMeetingUpdated: ((MeetingHistoryItem) -> Void)?
    var onWarning: ((String, String, Bool) -> Void)?
    
    init(
        llmManager: LLMManager,
        refinementCoordinator: RefinementCoordinator,
        summaryService: AINotesSummaryGenerating? = nil,
        generationGate: AINotesGenerationGate = AINotesGenerationGate()
    ) {
        self.llmManager = llmManager
        self.refinementCoordinator = refinementCoordinator
        self.summaryService = summaryService ?? AINotesSummaryService(llmManager: llmManager)
        self.generationGate = generationGate
    }
    
    var canGenerateSummaries: Bool {
        llmManager.hasModel && llmManager.isLLMStitchingEnabled
    }
    
    func isGeneratingSummary(for meeting: MeetingHistoryItem) -> Bool {
        activeTasks[meeting.id] != nil
    }
    
    func cancelSummary(for meeting: MeetingHistoryItem) {
        activeTasks[meeting.id]?.cancel()
        activeTasks.removeValue(forKey: meeting.id)
        meeting.isLoadingAISummary = false
    }
    
    func setContentMode(_ mode: MeetingHistoryItem.ContentViewMode, for meeting: MeetingHistoryItem) {
        if mode == .aiSummary && !meeting.hasAISummary {
            return
        }
        meeting.contentViewMode = mode
    }
    
    func generateSummary(for meeting: MeetingHistoryItem, prompt: String, force: Bool = false) {
        guard activeTasks[meeting.id] == nil else { return }
        
        let now = Date()
        if !force, let last = lastStartAt[meeting.id], now.timeIntervalSince(last) < 0.75 {
            return
        }
        lastStartAt[meeting.id] = now
        
        let transcript = (meeting.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            onWarning?(
                "AI notes unavailable",
                "Transcript is empty for '\(meeting.title)'. Load transcript before generating AI notes.",
                true
            )
            return
        }
        
        if refinementCoordinator.isRefining {
            onWarning?(
                "AI notes waiting",
                "Transcript refinement is in progress. Try generating AI notes again once refinement finishes.",
                true
            )
            return
        }
        
        let normalizedPrompt = PreferencesManager.normalizeAISummaryPrompt(prompt)
        let sourceFingerprint = Self.fingerprint(
            transcript + "\n\nPROMPT:\(normalizedPrompt)\nMODEL:\(llmManager.activeModel?.rawValue ?? "none")"
        )
        
        let summaryURL = meeting.directory.appendingPathComponent("ai_summary.md")
        if !force, isManualEditDetected(summaryURL: summaryURL, sourceFingerprint: sourceFingerprint) {
            onWarning?(
                "AI notes preserved",
                "Detected manual edits in ai_summary.md for '\(meeting.title)'. Auto-generation will not overwrite manual notes unless force regenerate is used.",
                true
            )
            return
        }
        
        if !force, lastSourceFingerprint[meeting.id] == sourceFingerprint {
            return
        }
        
        meeting.isLoadingAISummary = true
        let task = Task { [weak self] in
            guard let self = self else { return }
            defer {
                Task { @MainActor in
                    self.activeTasks.removeValue(forKey: meeting.id)
                    meeting.isLoadingAISummary = false
                }
            }
            
            do {
                if self.llmManager.modelContainer == nil, let model = self.llmManager.activeModel {
                    try await self.llmManager.loadModel(model)
                }
                
                try await self.generationGate.acquire()
                defer {
                    Task {
                        await self.generationGate.release()
                    }
                }
                
                let summary = try await self.summaryService.summarize(
                    transcript: transcript,
                    userPrompt: normalizedPrompt
                )
                
                try Task.checkCancellation()
                
                let summaryFingerprint = Self.fingerprint(summary)
                let state = GenerationState(
                    sourceFingerprint: sourceFingerprint,
                    summaryFingerprint: summaryFingerprint
                )
                try await Self.writeSummary(summary, state: state, to: summaryURL)
                
                await MainActor.run {
                    meeting.aiSummary = summary
                    meeting.hasAISummary = true
                    meeting.contentViewMode = .aiSummary
                    self.lastSourceFingerprint[meeting.id] = sourceFingerprint
                    self.onMeetingUpdated?(meeting)
                }
            } catch is CancellationError {
                self.logger.debug("Cancelled AI summary generation for \(meeting.title)")
            } catch {
                self.onWarning?(
                    "AI notes failed",
                    "Could not generate AI notes for '\(meeting.title)': \(error.localizedDescription)",
                    true
                )
                self.logger.error("AI summary generation failed: \(error.localizedDescription)")
            }
        }
        
        activeTasks[meeting.id] = task
    }
    
    private func isManualEditDetected(summaryURL: URL, sourceFingerprint: String) -> Bool {
        guard
            let content = try? String(contentsOf: summaryURL, encoding: .utf8),
            !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let state = Self.readState(from: summaryURL.deletingLastPathComponent())
        else {
            return false
        }
        
        if state.sourceFingerprint != sourceFingerprint {
            return false
        }
        let currentFingerprint = Self.fingerprint(content)
        return currentFingerprint != state.summaryFingerprint
    }
    
    private static func writeSummary(_ summary: String, state: GenerationState, to summaryURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            try summary.write(to: summaryURL, atomically: true, encoding: .utf8)
            let stateURL = summaryURL.deletingLastPathComponent().appendingPathComponent(".ai_summary_state.json")
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateURL)
        }.value
    }
    
    private static func readState(from directory: URL) -> GenerationState? {
        let url = directory.appendingPathComponent(".ai_summary_state.json")
        guard
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(GenerationState.self, from: data)
        else {
            return nil
        }
        return decoded
    }
    
    private static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }
}
