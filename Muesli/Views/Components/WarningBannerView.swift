import SwiftUI

/// A single warning banner that displays a service warning
/// Shows warning icon, category, message, and action buttons
struct WarningBannerView: View {
    let warning: ServiceWarning
    let onDismiss: () -> Void
    let onCopy: () -> Void
    var onRetry: (() -> Void)?
    
    @State private var showCopiedFeedback = false
    
    var body: some View {
        HStack(spacing: 8) {
            // Warning icon
            Image(systemName: warning.category.iconName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.orange)
            
            // Message
            Text(warning.message)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
            
            Spacer()
            
            // Action buttons
            HStack(spacing: 4) {
                // Retry button (if applicable)
                if warning.canRetry, let onRetry = onRetry {
                    Button(action: onRetry) {
                        Text("Retry")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                
                // Copy details button
                Button(action: {
                    onCopy()
                    showCopiedFeedback = true
                    
                    // Hide feedback after 2 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        showCopiedFeedback = false
                    }
                }) {
                    HStack(spacing: 2) {
                        Image(systemName: showCopiedFeedback ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(showCopiedFeedback ? "Copied" : "Copy")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .animation(.easeInOut(duration: 0.2), value: showCopiedFeedback)
                
                // Dismiss button
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

/// A stack of warning banners that displays all active warnings
struct WarningBannerStack: View {
    let warnings: [ServiceWarning]
    let onDismiss: (UUID) -> Void
    let onCopy: (UUID) -> Void
    var onRetry: ((ServiceWarning.WarningCategory) -> Void)?
    
    var body: some View {
        if !warnings.isEmpty {
            VStack(spacing: 6) {
                ForEach(warnings) { warning in
                    WarningBannerView(
                        warning: warning,
                        onDismiss: { onDismiss(warning.id) },
                        onCopy: { onCopy(warning.id) },
                        onRetry: warning.canRetry ? { onRetry?(warning.category) } : nil
                    )
                    .transition(.asymmetric(
                        insertion: .push(from: .top).combined(with: .opacity),
                        removal: .push(from: .bottom).combined(with: .opacity)
                    ))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .animation(.easeInOut(duration: 0.25), value: warnings.map(\.id))
        }
    }
}

// MARK: - Preview

#Preview("Single Warning") {
    VStack {
        WarningBannerView(
            warning: ServiceWarning(
                category: .microphone,
                message: "Microphone unavailable",
                details: "Error details here",
                canRetry: true
            ),
            onDismiss: {},
            onCopy: {},
            onRetry: {}
        )
        .padding()
        
        WarningBannerView(
            warning: ServiceWarning(
                category: .transcription,
                message: "Transcription error",
                details: "Error details here",
                canRetry: false
            ),
            onDismiss: {},
            onCopy: {}
        )
        .padding()
    }
    .frame(width: 400)
}

#Preview("Warning Stack") {
    WarningBannerStack(
        warnings: [
            ServiceWarning(
                category: .microphone,
                message: "Microphone unavailable",
                details: "Error details",
                canRetry: true
            ),
            ServiceWarning(
                category: .transcription,
                message: "Transcription error",
                details: "Error details",
                canRetry: false
            )
        ],
        onDismiss: { _ in },
        onCopy: { _ in },
        onRetry: { _ in }
    )
    .frame(width: 400)
}
