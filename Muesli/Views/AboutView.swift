import SwiftUI

/// About dialog window for Muesli
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var updateStatus: UpdateChecker.UpdateStatus?
    @State private var isCheckingForUpdates = false
    @State private var showUpdateSheet = false
    
    private var updateHelper: UpdateCheckHelper {
        UpdateCheckHelper(
            updateStatus: $updateStatus,
            showUpdateSheet: $showUpdateSheet,
            isCheckingForUpdates: $isCheckingForUpdates
        )
    }
    
    var body: some View {
        VStack(spacing: 20) {
            // App icon
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
            
            // App name
            Text(appName)
                .font(.system(size: 28, weight: .bold))
            
            // Version
            Text("Version \(appVersion)")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            
            // Update check section
            VStack(spacing: 8) {
                if isCheckingForUpdates {
                    Text("Checking for updates...")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else if case .upToDate = updateStatus {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("You're up to date")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                } else if case .updateAvailable(let version, _, _) = updateStatus {
                    Text("Version \(version) available")
                        .font(.system(size: 12))
                        .foregroundStyle(.blue)
                } else if case .error(let message) = updateStatus {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                
            // Check for Updates button
            Button(
                action: {
                    Task {
                        await updateHelper.checkForUpdates()
                    }
                },
                label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle")
                        Text("Check for Updates")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle({
                        if case .updateAvailable = updateStatus {
                            return Color.white
                        }
                        return Color.primary
                    }() as Color)
                    .frame(width: 180)
                    .padding(.vertical, 8)
                    .background({
                        if case .updateAvailable = updateStatus {
                            return Color.accentColor
                        }
                        return Color.secondary.opacity(0.15)
                    }() as Color)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            )
            .buttonStyle(.plain)
            .disabled(isCheckingForUpdates)
                
                // Last check date
                if let lastCheck = UpdateChecker.shared.lastCheckDate {
                    Text("Last checked: \(formatLastCheck(lastCheck))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 4)
            
            // Copyright
            Text("© 2024 Muesli")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            
            // Description
            Text("Local-first meeting transcription for macOS")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Spacer()
                .frame(height: 10)
            
            // OK button
            Button("OK") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .frame(width: 100)
        }
        .padding(40)
        .frame(width: 400, height: 600)
        .sheet(isPresented: $showUpdateSheet) {
            updateHelper.updateSheet(currentVersion: appVersion)
        }
        .onAppear {
            // Load cached update status if available
            if let lastCheck = UpdateChecker.shared.lastCheckDate,
               Date().timeIntervalSince(lastCheck) < 3600 { // Within last hour
                Task {
                    updateStatus = await UpdateChecker.shared.checkForUpdates()
                }
            }
        }
    }
    
    private func formatLastCheck(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    
    private var appName: String {
        Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Muesli"
    }
    
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

#Preview {
    AboutView()
}
