import SwiftUI

/// Sheet showing transcript refinement progress
struct RefineTranscriptSheet: View {
    @Binding var isPresented: Bool
    let progress: Double
    let isRefining: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            if isRefining {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                
                Text("Refining transcript...")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            } else if let error = errorMessage {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48))
                    .foregroundStyle(.red)
                
                Text("Refinement Failed")
                    .font(.headline)
                
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Button("Cancel", role: .cancel) {
                onCancel()
                isPresented = false
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(width: 400)
    }
}
