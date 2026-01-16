import SwiftUI

/// Window for viewing a completed meeting transcript
/// Provides full meeting functionality: reprocess, resume recording, refinement toggle, rich transcript display
struct CompletedMeetingWindow: View {
    let meeting: MeetingHistoryItem
    @Bindable var viewModel: MuesliViewModel
    @Environment(MeetingHistoryManager.self) private var historyManager
    @Environment(RefinementCoordinator.self) private var refinementCoordinator
    
    var body: some View {
        @Bindable var history = historyManager
        
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // Header
                headerView
                
                Divider()
                
                // Content
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Metadata row with date, Open in Finder, and Delete
                        metadataRow
                        
                        // Show recording start time for resumable meetings
                        recordingStartTimeView
                        
                        // Transcript display
                        transcriptView
                    }
                    .padding(20)
                    .padding(.bottom, 80) // Space for floating control pane
                }
            }
            
            // Floating control pane: resume/refinement controls
            ResumeControlPane(viewModel: viewModel, meeting: meeting)
                .padding(.bottom, 16)
        }
        .frame(minWidth: 600, minHeight: 500)
        .background(.background)
        .onAppear {
            loadTranscript()
        }
        .alert("Delete Meeting?", isPresented: $history.showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                historyManager.cancelDeleteMeetings()
            }
            Button("Delete", role: .destructive) {
                historyManager.confirmDeleteMeetings()
            }
        } message: {
            if let meeting = historyManager.meetingsPendingDeletion.first {
                Text("This will permanently delete \"\(meeting.title)\" and its audio files.")
            }
        }
    }
    
    // MARK: - Header View
    
    private var headerView: some View {
        HStack(spacing: 12) {
            TextField("Meeting Title", text: Binding(
                get: { meeting.title },
                set: { meeting.title = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.primary)
            
            Spacer()
            
            // Reprocess button with model picker
            if viewModel.modelManager.downloadedModels.count > 0 {
                Menu {
                    ForEach(viewModel.modelManager.downloadedModelsOrdered, id: \.self) { model in
                        Button("Reprocess with \(model.displayName)") {
                            viewModel.reprocessTranscript(for: meeting, using: model)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if meeting.isReprocessing {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 12, height: 12)
                            Text("Reprocessing...")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12))
                            Text("Reprocess")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .disabled(meeting.isReprocessing)
                .help("Re-transcribe this recording with a different model")
            }
            
            CompletedIndicator()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
    
    // MARK: - Metadata Row
    
    private var metadataRow: some View {
        HStack(spacing: 8) {
            Label(formatDate(meeting.date), systemImage: "calendar")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            
            Text("·")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            
            Button(action: {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: meeting.directory.path)
            }) {
                Text("Open in Finder")
                    .font(.system(size: 12))
                    .foregroundStyle(.blue)
                    .underline()
            }
            .buttonStyle(.plain)
            
            Text("·")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            
            Button(action: {
                historyManager.requestDeleteMeeting(meeting)
            }) {
                Text("Delete Recording")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .underline()
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 8)
    }
    
    // MARK: - Recording Start Time
    
    @ViewBuilder
    private var recordingStartTimeView: some View {
        if meeting.canResume, let firstSegment = meeting.transcriptSegments.first {
            let formatter: DateFormatter = {
                let f = DateFormatter()
                f.dateStyle = .medium
                f.timeStyle = .short
                return f
            }()
            Text("Recording started: \(formatter.string(from: firstSegment.startTime))")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
    }
    
    // MARK: - Transcript View
    
    @ViewBuilder
    private var transcriptView: some View {
        // Transcript - prefer segments, then blocks, then plain text
        if !meeting.transcriptSegments.isEmpty {
            // Segment-based display with markers
            LazyVStack(spacing: 8) {
                ForEach(meeting.transcriptSegments.sorted(by: { $0.segmentNumber < $1.segmentNumber })) { segment in
                    Group {
                        // Segment marker (except for first segment)
                        if segment.segmentNumber > 1 {
                            let formatter: DateFormatter = {
                                let f = DateFormatter()
                                f.dateStyle = .none
                                f.timeStyle = .short
                                return f
                            }()
                            Text("Recording resumed at \(formatter.string(from: segment.startTime))")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 8)
                        }
                        
                        // Blocks for this segment
                        let blocksToShow = (meeting.isShowingRefined && segment.isRefined) ?
                            (segment.refinedBlocks ?? segment.originalBlocks) :
                            segment.originalBlocks
                        
                        ForEach(blocksToShow) { block in
                            TranscriptBlockView(block: block)
                        }
                    }
                }
            }
        } else {
            // Fallback to block-based or plain text display
            let hasOriginal = (meeting.originalTranscriptBlocks != nil || meeting.originalTranscript != nil)
            let showingOriginal = viewModel.showOriginalTranscript(for: meeting) && hasOriginal
            
            if let blocks = meeting.transcriptBlocks, !blocks.isEmpty {
                // Block-based display (new format)
                LazyVStack(spacing: 8) {
                    ForEach(showingOriginal ? (meeting.originalTranscriptBlocks ?? blocks) : blocks) { block in
                        TranscriptBlockView(block: block)
                    }
                }
            } else if let transcript = meeting.transcript {
                // Plain text display (legacy format)
                Text(showingOriginal ? (meeting.originalTranscript ?? transcript) : transcript)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Loading state
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading transcript...")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    
    // MARK: - Helpers
    
    private func loadTranscript() {
        if meeting.transcript == nil && meeting.transcriptBlocks == nil {
            Task {
                await historyManager.loadTranscript(for: meeting)
            }
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

#Preview {
    let vm = MuesliViewModel()
    let historyManager = MeetingHistoryManager()
    let refinementCoordinator = RefinementCoordinator(llmManager: LLMManager(), fileOutputService: FileOutputService())
    let meeting = MeetingHistoryItem(
        title: "Team Standup",
        date: Date(),
        directory: URL(fileURLWithPath: "/tmp/test"),
        hasAudio: true,
        hasMicrophone: true
    )
    return CompletedMeetingWindow(meeting: meeting, viewModel: vm)
        .environment(historyManager)
        .environment(refinementCoordinator)
        .frame(width: 600, height: 500)
}
