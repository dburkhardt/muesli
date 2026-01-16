import SwiftUI

/// Modal sheet shown when an app update is available
struct UpdateSheet: View {
    let currentVersion: String
    let newVersion: String
    let releaseNotes: String
    let downloadURL: URL
    let onDownload: () -> Void
    let onSkip: () -> Void
    let onRemindLater: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            // Icon
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            
            // Title
            Text("Update Available")
                .font(.title2.bold())
            
            // Version info
            HStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text("Current")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(currentVersion)
                        .font(.system(size: 16, weight: .medium))
                }
                
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                
                VStack(spacing: 4) {
                    Text("New")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(newVersion)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 24)
            
            // Release notes
            VStack(alignment: .leading, spacing: 8) {
                Text("What's New")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                
                ScrollView {
                    Text(releaseNotes)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                .padding(12)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(maxWidth: 380)
            
            // Action buttons
            VStack(spacing: 10) {
                // Primary action: Download
                Button(action: onDownload) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Download Update")
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                
                // Secondary actions
                HStack(spacing: 10) {
                    Button(action: onSkip) {
                        Text("Skip This Version")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: onRemindLater) {
                        Text("Remind Me Later")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                }
            }
            .frame(maxWidth: 350)
        }
        .padding(32)
        .frame(width: 480)
    }
}

#Preview("Update Available") {
    UpdateSheet(
        currentVersion: "0.1.0",
        newVersion: "0.2.0",
        releaseNotes: """
        ## What's New
        
        - Improved transcription accuracy
        - Added support for larger models
        - Bug fixes and performance improvements
        - Enhanced UI for better user experience
        
        ## Bug Fixes
        
        - Fixed issue with microphone detection
        - Resolved memory leak in audio processing
        """,
        downloadURL: URL(string: "https://github.com/dburkhardt/muesli/releases/latest")!,
        onDownload: {
            print("Download tapped")
        },
        onSkip: {
            print("Skip tapped")
        },
        onRemindLater: {
            print("Remind later tapped")
        }
    )
    .background(.regularMaterial)
}
