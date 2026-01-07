import SwiftUI

/// Window for viewing a completed meeting transcript while recording is active
struct CompletedMeetingWindow: View {
    let meeting: MeetingHistoryItem
    let viewModel: MuesliViewModel
    @State private var transcript: String?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                TextField("Meeting Title", text: Binding(
                    get: { meeting.title },
                    set: { meeting.title = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
                
                Spacer()
                
                CompletedIndicator()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            
            Divider()
            
            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Metadata
                    HStack(spacing: 16) {
                        Label(formatDate(meeting.date), systemImage: "calendar")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        
                        if meeting.hasAudio {
                            Label("System Audio", systemImage: "speaker.wave.2")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        
                        if meeting.hasMicrophone {
                            Label("Microphone", systemImage: "mic")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 8)
                    
                    // Transcript
                    if let transcript = transcript ?? meeting.transcript {
                        Text(transcript)
                            .font(.system(size: 14))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
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
                .padding(20)
            }
            
            // Footer
            Divider()
            
            HStack(spacing: 12) {
                Spacer()
                
                Button(action: {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: meeting.directory.path)
                }) {
                    Text("Open in Finder")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                
                Spacer()
            }
            .padding(16)
        }
        .frame(minWidth: 600, minHeight: 500)
        .background(.background)
        .onAppear {
            loadTranscript()
        }
    }
    
    // MARK: - Helpers
    
    private func loadTranscript() {
        if meeting.transcript == nil {
            viewModel.loadTranscript(for: meeting)
            transcript = meeting.transcript
        } else {
            transcript = meeting.transcript
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
    let meeting = MeetingHistoryItem(
        title: "Team Standup",
        date: Date(),
        directory: URL(fileURLWithPath: "/tmp/test"),
        hasAudio: true,
        hasMicrophone: true
    )
    return CompletedMeetingWindow(meeting: meeting, viewModel: vm)
        .frame(width: 600, height: 500)
}
