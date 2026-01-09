import SwiftUI

/// Floating control pane for resumable meetings
/// Shows Original/Refined toggle and Resume button
struct ResumeControlPane: View {
    @Bindable var viewModel: MuesliViewModel
    let meeting: MeetingHistoryItem
    
    var body: some View {
        HStack(spacing: 16) {
            // Original/Refined toggle (only show if at least one segment is refined)
            if meeting.transcriptSegments.contains(where: { $0.isRefined }) {
                Toggle(isOn: Binding(
                    get: { meeting.isShowingRefined },
                    set: { newValue in
                        meeting.isShowingRefined = newValue
                        viewModel.updateMeetingTranscriptDisplay(meeting)
                    }
                )) {
                    HStack(spacing: 6) {
                        Image(systemName: meeting.isShowingRefined ? "wand.and.stars" : "doc.text")
                            .font(.system(size: 14))
                        Text(meeting.isShowingRefined ? "Refined" : "Original")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .toggleStyle(.switch)
            }
            
            Divider()
                .frame(height: 20)
            
            // Resume button
            Button(action: {
                viewModel.resumeRecording(for: meeting)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 14))
                    Text("Resume")
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.activeRecordingSession != nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            Capsule()
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
        }
    }
}
