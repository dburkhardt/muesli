import SwiftUI

/// Floating control pane for resumable meetings
/// Shows Original/Refined toggle (icon-only) and Resume button
/// During active recording, shows recording controls instead
struct ResumeControlPane: View {
    @Bindable var viewModel: MuesliViewModel
    let meeting: MeetingHistoryItem
    
    /// Check if refinement is in progress OR pending (segments exist but not yet refined)
    private var isRefiningOrPending: Bool {
        // Actively refining
        if viewModel.refinementCoordinator.isRefining {
            return true
        }
        // Has segments that haven't been refined yet (refinement pending)
        let hasUnrefinedSegments = meeting.transcriptSegments.contains(where: { !$0.isRefined })
        return hasUnrefinedSegments && viewModel.canRefineTranscripts
    }
    
    /// Check if meeting has refined content (segments or meeting-level)
    private var hasRefinedContent: Bool {
        // Check segment-based refinement
        let hasRefinedSegments = meeting.transcriptSegments.contains(where: { $0.isRefined })
        // Check meeting-level refinement (old format)
        let hasMeetingLevelRefinement =
            meeting.isRefined || meeting.originalTranscriptBlocks != nil || meeting.originalTranscript != nil
        return hasRefinedSegments || hasMeetingLevelRefinement
    }
    
    /// Check if using segment-based refinement
    private var usesSegments: Bool {
        !meeting.transcriptSegments.isEmpty
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Show refinement loading indicator OR toggle (mutually exclusive)
            if isRefiningOrPending {
                RefinementLoadingIndicator()
            } else if hasRefinedContent {
                // Original/Refined toggle - works for both segment-based and meeting-level refinement
                if usesSegments {
                    // Segment-based toggle
                    RefinementToggleControl(
                        isOn: Binding(
                            get: { meeting.isShowingRefined },
                            set: { newValue in
                                meeting.isShowingRefined = newValue
                                viewModel.updateMeetingTranscriptDisplay(meeting)
                            }
                        )
                    )
                } else {
                    // Meeting-level toggle (old format)
                    RefinementToggleControl(
                        isOn: Binding(
                            get: { !viewModel.showOriginalTranscript(for: meeting) },
                            set: { _ in viewModel.toggleOriginalTranscript(for: meeting) }
                        )
                    )
                }
            }
            
            // Always show divider and resume button (even during refining)
            if isRefiningOrPending || hasRefinedContent {
                Divider()
                    .frame(height: 20)
            }
            
        // Resume button - always visible, flat icon style
        Button(
            action: {
                viewModel.resumeRecording(for: meeting)
            },
            label: {
                Image(systemName: "record.circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.5))
            }
        )
        .buttonStyle(.plain)
        .disabled(viewModel.activeRecordingSession != nil)
        .opacity(viewModel.activeRecordingSession != nil ? 0.3 : 1.0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            Capsule()
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
        }
    }
}
