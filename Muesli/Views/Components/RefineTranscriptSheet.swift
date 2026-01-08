import SwiftUI

/// Sheet displayed during transcript refinement
/// Shows progress and allows cancellation
struct RefineTranscriptSheet: View {
    @Binding var isPresented: Bool
    let progress: Double
    let isRefining: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            // Icon
            if let error = errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
            } else if isRefining {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 40))
                    .foregroundStyle(.purple)
                    .symbolEffect(.pulse, isActive: isRefining)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.green)
            }
            
            // Title
            Text(title)
                .font(.headline)
            
            // Progress or error
            if let error = errorMessage {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            } else if isRefining {
                VStack(spacing: 8) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 200)
                    
                    Text("\(Int(progress * 100))% complete")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Your transcript has been refined.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            // Action buttons
            HStack(spacing: 12) {
                if isRefining {
                    Button("Cancel") {
                        onCancel()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Done") {
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 320)
    }
    
    private var title: String {
        if errorMessage != nil {
            return "Refinement Failed"
        } else if isRefining {
            return "Refining Transcript..."
        } else {
            return "Refinement Complete"
        }
    }
}

/// Post-meeting prompt to offer refinement
struct PostMeetingRefinementPrompt: View {
    @Binding var isPresented: Bool
    let hasLLMModel: Bool
    let onRefine: () -> Void
    let onSkip: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 40))
                .foregroundStyle(.purple)
            
            Text("Refine Transcript?")
                .font(.headline)
            
            Text("Use AI to clean up the transcript - fix spelling, punctuation, and remove audio artifacts.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            
            if !hasLLMModel {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("No LLM model downloaded")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            
            HStack(spacing: 12) {
                Button("Skip") {
                    onSkip()
                    isPresented = false
                }
                .buttonStyle(.bordered)
                
                Button("Refine Now") {
                    onRefine()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasLLMModel)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 340)
    }
}

#Preview("Refining") {
    RefineTranscriptSheet(
        isPresented: .constant(true),
        progress: 0.45,
        isRefining: true,
        errorMessage: nil,
        onCancel: {}
    )
}

#Preview("Complete") {
    RefineTranscriptSheet(
        isPresented: .constant(true),
        progress: 1.0,
        isRefining: false,
        errorMessage: nil,
        onCancel: {}
    )
}

#Preview("Error") {
    RefineTranscriptSheet(
        isPresented: .constant(true),
        progress: 0.3,
        isRefining: false,
        errorMessage: "Model failed to load. Please try again.",
        onCancel: {}
    )
}

#Preview("Post-Meeting Prompt") {
    PostMeetingRefinementPrompt(
        isPresented: .constant(true),
        hasLLMModel: true,
        onRefine: {},
        onSkip: {}
    )
}

#Preview("Post-Meeting No Model") {
    PostMeetingRefinementPrompt(
        isPresented: .constant(true),
        hasLLMModel: false,
        onRefine: {},
        onSkip: {}
    )
}
