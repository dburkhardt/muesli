import SwiftUI

/// Modal sheet shown when user tries to record without a transcription model
/// Offers two options: download a model or record audio-only
struct NoModelSheet: View {
    @Binding var isPresented: Bool
    let onDownload: () -> Void
    let onRecordOnly: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            // Icon
            Image(systemName: "brain.head.profile")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            
            // Title
            Text("No Transcription Model")
                .font(.title2.bold())
            
            // Description
            Text(
                """
                Muesli needs a transcription model to generate live transcripts. \
                You can download one now or record audio-only.
                """
            )
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)
            
            // Action buttons
            VStack(spacing: 12) {
            // Primary action: Download model
            Button(
                action: {
                    isPresented = false
                    onDownload()
                },
                label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Download Model")
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            )
            .buttonStyle(.plain)
                
            // Secondary action: Record only
            Button(
                action: {
                    isPresented = false
                    onRecordOnly()
                },
                label: {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform")
                        Text("Record Audio Only")
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            )
            .buttonStyle(.plain)
            }
            .frame(maxWidth: 280)
        }
        .padding(32)
        .frame(width: 420)
    }
}

#Preview("No Model Sheet") {
    NoModelSheet(
        isPresented: .constant(true),
        onDownload: {},
        onRecordOnly: {}
    )
    .background(.regularMaterial)
}
