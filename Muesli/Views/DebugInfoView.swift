import AVFoundation
import SwiftUI

/// Debug information panel showing permission states, bundle info, and log location
/// Accessible from menu bar during both onboarding and normal operation
struct DebugInfoView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var logFilePath: String = ""
    @State private var logsDirectoryPath: String = ""
    
    private var appName: String {
        Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Muesli"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("Debug Information")
                    .font(.headline)
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Build Info Section
                    buildInfoSection
                    
                    Divider()
                    
                    // Permission States Section
                    permissionStatesSection
                    
                    Divider()
                    
                    // Onboarding State Section
                    onboardingStateSection
                    
                    Divider()
                    
                    // Info.plist Keys Section
                    infoPlistSection
                    
                    Divider()
                    
                    // Log File Section
                    logFileSection
                }
                .padding(.trailing, 8)
            }
            
            Divider()
            
            // Actions
            HStack {
                Button("Copy All") {
                    copyAllToClipboard()
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("Open Logs in Finder") {
                    openLogsInFinder()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(width: 500, height: 550)
        .task {
            // Get log file paths from DiagnosticLogger
            logFilePath = await DiagnosticLogger.shared.getLogFilePath()
            logsDirectoryPath = await DiagnosticLogger.shared.getLogsDirectoryPath()
        }
    }
    
    // MARK: - Sections
    
    private var buildInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Build Information")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            
            infoRow("Bundle ID", value: Bundle.main.bundleIdentifier ?? "unknown")
            infoRow("Version", value: versionString)
            infoRow("Configuration", value: buildConfiguration)
        }
    }
    
    private var permissionStatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permission States")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            
            // Microphone - safe to check, doesn't trigger prompt
            let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            infoRow("Microphone", value: "\(micStatus.rawValue) (\(statusName(micStatus)))")
            
            // Screen Recording - use cached value to avoid triggering prompt
            // CGPreflightScreenCaptureAccess is unreliable but safe
            let screenRecordingCached = CGPreflightScreenCaptureAccess()
            infoRow("Screen Recording (cached)", value: "\(screenRecordingCached)")
            
            Text("Note: Screen recording value may be stale with ad-hoc signing")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
    
    private var onboardingStateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Onboarding State")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            
            let hasCompleted = UserDefaults.standard.bool(forKey: AppStorageKeys.hasCompletedOnboarding)
            infoRow("hasCompletedOnboarding", value: "\(hasCompleted)")
            
            let currentStep = UserDefaults.standard.integer(forKey: AppStorageKeys.onboardingCurrentStep)
            infoRow("onboardingCurrentStep", value: "\(currentStep)")
        }
    }
    
    private var infoPlistSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Info.plist Permission Keys")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            
            let micDesc = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
            infoRow("NSMicrophoneUsageDescription", value: micDesc ?? "MISSING", isMissing: micDesc == nil)
            
            let screenDesc = Bundle.main.object(forInfoDictionaryKey: "NSScreenCaptureUsageDescription") as? String
            infoRow("NSScreenCaptureUsageDescription", value: screenDesc ?? "MISSING", isMissing: screenDesc == nil)
        }
    }
    
    private var logFileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Diagnostic Logs")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Location:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(logsDirectoryPath)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Current Log File:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(logFilePath)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }
    
    // MARK: - Helper Views
    
    private func infoRow(_ label: String, value: String, isMissing: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label + ":")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 200, alignment: .leading)
            
            Text(value)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(isMissing ? .red : .primary)
                .textSelection(.enabled)
            
            Spacer()
        }
    }
    
    // MARK: - Computed Properties
    
    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return "\(version) (\(build))"
    }
    
    private var buildConfiguration: String {
        #if DEBUG
        return "DEBUG"
        #else
        return "RELEASE"
        #endif
    }
    
    // MARK: - Actions
    
    private func copyAllToClipboard() {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let screenRecordingCached = CGPreflightScreenCaptureAccess()
        let hasCompleted = UserDefaults.standard.bool(forKey: AppStorageKeys.hasCompletedOnboarding)
        let currentStep = UserDefaults.standard.integer(forKey: AppStorageKeys.onboardingCurrentStep)
        let micDesc = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
        let screenDesc = Bundle.main.object(forInfoDictionaryKey: "NSScreenCaptureUsageDescription") as? String
        
        let info = """
        === \(appName) Debug Information ===
        
        Build Information:
        - Bundle ID: \(Bundle.main.bundleIdentifier ?? "unknown")
        - Version: \(versionString)
        - Configuration: \(buildConfiguration)
        
        Permission States:
        - Microphone: \(micStatus.rawValue) (\(statusName(micStatus)))
        - Screen Recording (cached): \(screenRecordingCached)
        
        Onboarding State:
        - hasCompletedOnboarding: \(hasCompleted)
        - onboardingCurrentStep: \(currentStep)
        
        Info.plist Keys:
        - NSMicrophoneUsageDescription: \(micDesc ?? "MISSING")
        - NSScreenCaptureUsageDescription: \(screenDesc ?? "MISSING")
        
        Diagnostic Logs:
        - Location: \(logsDirectoryPath)
        - Current File: \(logFilePath)
        """
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info, forType: .string)
    }
    
    private func openLogsInFinder() {
        let url = URL(fileURLWithPath: logsDirectoryPath)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }
    
    private func statusName(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }
}
