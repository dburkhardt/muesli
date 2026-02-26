import SwiftUI

/// Displays a single transcript block with speaker-specific styling
/// - Light gray background for "Them"
/// - White/clear background for "Me"
/// - Timestamp shown on hover
struct TranscriptBlockView: View {
    let block: TranscriptBlock
    
    @State private var isHovering = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Speaker label with subtle styling
            HStack(spacing: 6) {
                // Small colored indicator dot
                Circle()
                    .fill(speakerAccentColor)
                    .frame(width: 6, height: 6)
                
                Text(block.speaker.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                // Timestamp on hover
                if isHovering {
                    Text(block.formattedStartTime)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            
            // Text content
            Text(block.text)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineSpacing(3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor, lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
    
    // MARK: - Styling
    
    private var backgroundColor: Color {
        switch block.speaker {
        case .them:
            return Color.secondary.opacity(0.08)  // Light gray
        case .me:
            return Color.blue.opacity(0.08)  // Light blue tint for "Me" blocks
        }
    }
    
    private var speakerAccentColor: Color {
        switch block.speaker {
        case .them:
            return Color.secondary
        case .me:
            return Color.blue
        }
    }

    private var borderColor: Color {
        switch block.speaker {
        case .them:
            return Color.secondary.opacity(0.14)
        case .me:
            return Color.blue.opacity(0.22)
        }
    }
}

// MARK: - Preview

#Preview("Them Block") {
    TranscriptBlockView(
        block: TranscriptBlock(
            speaker: .them,
            text: """
                Good morning everyone, let's get started with the quarterly review. \
                I wanted to go over the main highlights from last quarter and discuss our plans for the upcoming sprint.
                """,
            startTimestamp: 5
        )
    )
    .padding()
    .frame(width: 500)
}

#Preview("Me Block") {
    TranscriptBlockView(
        block: TranscriptBlock(
            speaker: .me,
            text: """
                Thanks for setting this up. I had a few questions about the timeline \
                and wanted to discuss the resource allocation.
                """,
            startTimestamp: 32
        )
    )
    .padding()
    .frame(width: 500)
}

#Preview("Conversation") {
    VStack(spacing: 8) {
        TranscriptBlockView(
            block: TranscriptBlock(
                speaker: .them,
                text: "Good morning everyone, let's get started with the quarterly review.",
                startTimestamp: 5
            )
        )
        TranscriptBlockView(
            block: TranscriptBlock(
                speaker: .me,
                text: "Thanks for setting this up. I had a few questions about the timeline.",
                startTimestamp: 32
            )
        )
        TranscriptBlockView(
            block: TranscriptBlock(
                speaker: .them,
                text: """
                    Sure thing. So first item on the agenda is the product roadmap. \
                    We've made good progress on the main features and I think we're on track for the release.
                    """,
                startTimestamp: 45
            )
        )
    }
    .padding()
    .frame(width: 500)
    .background(Color(nsColor: .windowBackgroundColor))
}
