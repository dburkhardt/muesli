import SwiftUI

/// Floating indicator showing active model downloads
/// Displayed in the main window when downloads are in progress after onboarding
struct DownloadIndicatorView: View {
    @Bindable var viewModel: MuesliViewModel
    
    var body: some View {
        if viewModel.isAnyModelDownloading {
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(viewModel.activeDownloads, id: \.name) { download in
                    downloadPill(name: download.name, progress: download.progress)
                }
            }
        }
    }
    
    private func downloadPill(name: String, progress: Double) -> some View {
        HStack(spacing: 8) {
            // Download icon
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 12))
                .foregroundStyle(.blue)
            
            // Model name
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
            
            // Progress bar
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(width: 50)
            
            // Percentage
            Text("\(Int(progress * 100))%")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
            
            // Cancel button
            Button {
                viewModel.cancelActiveDownloads()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel download")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            Capsule()
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
        }
    }
}

/// Compact download indicator for use in areas with limited space
/// Shows only when transcription is unavailable due to downloading
struct CompactDownloadIndicator: View {
    @Bindable var viewModel: MuesliViewModel
    
    var body: some View {
        if viewModel.isAnyModelDownloading && !viewModel.modelManager.hasModel {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                
                Text("Downloading model...")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                
                if let firstDownload = viewModel.activeDownloads.first {
                    Text("\(Int(firstDownload.progress * 100))%")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.1))
            .clipShape(Capsule())
        }
    }
}

#Preview("Download Indicator") {
    let vm = MuesliViewModel()
    VStack {
        Spacer()
        HStack {
            Spacer()
            DownloadIndicatorView(viewModel: vm)
                .padding()
        }
    }
    .frame(width: 400, height: 300)
    .background(Color.gray.opacity(0.1))
}
