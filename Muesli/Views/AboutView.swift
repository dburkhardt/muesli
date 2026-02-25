import SwiftUI

/// About dialog window for Muesli
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var updateStatus: UpdateChecker.UpdateStatus?
    @State private var isCheckingForUpdates = false
    @State private var showUpdateSheet = false
    @State private var showBuildDetails = true
    @State private var copiedToClipboard = false
    
    private var updateHelper: UpdateCheckHelper {
        UpdateCheckHelper(
            updateStatus: $updateStatus,
            showUpdateSheet: $showUpdateSheet,
            isCheckingForUpdates: $isCheckingForUpdates
        )
    }
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    // App icon
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 128, height: 128)
                    
                    // App name
                    Text(appName)
                        .font(.system(size: 28, weight: .bold))
                    
                    // Version and build type badge
                    VStack(spacing: 6) {
                        Text("Version \(appVersion)")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                        
                        // DEV BUILD badge (only shown for non-release builds)
                        if BuildInfo.buildType == "DEV" {
                            Text("DEV BUILD")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.orange)
                                .clipShape(Capsule())
                        }
                    }
                    
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
                    
                    // Build Details (expandable)
                    buildDetailsSection
                    
                    // Copyright
                    Text("© 2026 Muesli")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 40)
                .padding(.top, 40)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            
            Divider()
            
            Button("OK") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .frame(width: 100)
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
        .frame(width: 420, height: 620)
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
    
    // MARK: - Build Details Section
    
    private var buildDetailsSection: some View {
        VStack(spacing: 8) {
            // Disclosure button
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showBuildDetails.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showBuildDetails ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Text("Build Details")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            
            if showBuildDetails {
                VStack(alignment: .leading, spacing: 4) {
                    buildDetailRow(label: "Commit", value: commitDisplay)
                    buildDetailRow(label: "Branch", value: BuildInfo.gitBranch)
                    buildDetailRow(label: "Built", value: BuildInfo.buildTimestamp)
                    if BuildInfo.isCIBuild {
                        buildDetailRow(label: "CI", value: BuildInfo.ciRunInfo)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                
                // Copy Build Info button
                Button {
                    copyBuildInfo()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copiedToClipboard ? "checkmark" : "doc.on.doc")
                        Text(copiedToClipboard ? "Copied!" : "Copy Build Info")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(copiedToClipboard ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
        }
        .padding(.vertical, 8)
    }
    
    private var commitDisplay: String {
        if BuildInfo.isDirty {
            return "\(BuildInfo.gitCommit) (dirty)"
        }
        return BuildInfo.gitCommit
    }
    
    private func buildDetailRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text("\(label):")
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
            Text(value)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer()
        }
    }
    
    private func copyBuildInfo() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(BuildInfo.fullDescription, forType: .string)
        
        copiedToClipboard = true
        
        // Reset after 2 seconds
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copiedToClipboard = false
        }
    }
}

#Preview {
    AboutView()
}
