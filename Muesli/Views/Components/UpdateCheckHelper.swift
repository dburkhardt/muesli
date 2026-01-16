import SwiftUI

/// Helper for managing update checking state and UI
/// Eliminates duplication between AboutView and MenuBarView
struct UpdateCheckHelper {
    @Binding var updateStatus: UpdateChecker.UpdateStatus?
    @Binding var showUpdateSheet: Bool
    @Binding var isCheckingForUpdates: Bool
    
    /// Performs an update check
    func checkForUpdates() async {
        isCheckingForUpdates = true
        updateStatus = await UpdateChecker.shared.checkForUpdates()
        isCheckingForUpdates = false
        if case .updateAvailable = updateStatus {
            showUpdateSheet = true
        }
    }
    
    /// Creates the UpdateSheet view for presentation
    @ViewBuilder
    func updateSheet(currentVersion: String) -> some View {
        if case .updateAvailable(let version, let notes, let url) = updateStatus {
            UpdateSheet(
                currentVersion: currentVersion,
                newVersion: version,
                releaseNotes: notes,
                downloadURL: url,
                onDownload: {
                    NSWorkspace.shared.open(url)
                    showUpdateSheet = false
                },
                onSkip: {
                    UpdateChecker.shared.skipVersion(version)
                    updateStatus = .upToDate
                    showUpdateSheet = false
                },
                onRemindLater: {
                    showUpdateSheet = false
                }
            )
        }
    }
}
