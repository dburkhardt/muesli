import SwiftUI

/// Content for the menu bar dropdown
struct MenuBarView: View {
    let viewModel: MuesliViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    
    /// Use @AppStorage so SwiftUI automatically observes UserDefaults changes
    @AppStorage(AppStorageKeys.hasCompletedOnboarding) private var hasCompletedOnboarding: Bool = false
    
    /// Update checking state
    @State private var updateStatus: UpdateChecker.UpdateStatus?
    @State private var showUpdateSheet = false
    @State private var isCheckingForUpdates = false
    
    private var updateHelper: UpdateCheckHelper {
        UpdateCheckHelper(
            updateStatus: $updateStatus,
            showUpdateSheet: $showUpdateSheet,
            isCheckingForUpdates: $isCheckingForUpdates
        )
    }
    
    private var appName: String {
        Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Muesli"
    }
    
    var body: some View {
        Group {
            // Show simplified menu during onboarding to prevent bypass
            if !hasCompletedOnboarding {
                onboardingMenuContent
            } else if let activeSession = viewModel.activeSession, activeSession.isRecording {
                recordingMenuContent(session: activeSession)
            } else {
                idleMenuContent
            }
        }
    }
    
    /// State for showing debug info sheet
    @State private var showDebugInfo = false
    
    // MARK: - Onboarding State Menu
    
    private var onboardingMenuContent: some View {
        Group {
            Button("Resume Set Up") {
                AppDelegate.shared?.bringOnboardingWindowToFront()
            }
            
            Divider()
            
            Button("Debug Info...") {
                showDebugInfo = true
            }
            
            Divider()
            
            Button("Quit \(appName)") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .sheet(isPresented: $showDebugInfo) {
            DebugInfoView()
        }
    }
    
    // MARK: - Idle State Menu
    
    private var idleMenuContent: some View {
        Group {
            // Quick start recording (captures all system audio)
            Button("Start Recording") {
                viewModel.quickStartRecording()
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("r", modifiers: .command)
            
            Divider()
            
            Button("Open \(appName)") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("o", modifiers: .command)
            
            Divider()
            
            Button("Preferences...") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: .command)
            
            Button("Debug Info...") {
                showDebugInfo = true
            }
            
            // Check for Updates menu item with indicator
            if let status = updateStatus, case .updateAvailable = status {
                Button {
                    showUpdateSheet = true
                } label: {
                    HStack {
                        Text("Update Available")
                        Circle()
                            .fill(.orange)
                            .frame(width: 8, height: 8)
                    }
                }
            } else {
                Button("Check for Updates...") {
                    Task {
                        await updateHelper.checkForUpdates()
                    }
                }
                .disabled(isCheckingForUpdates)
            }
            
            Divider()
            
            Button("Quit \(appName)") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .sheet(isPresented: $showUpdateSheet) {
            updateHelper.updateSheet(
                currentVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
            )
        }
        .onAppear {
            // Check for updates on menu bar open if we have a cached status from ViewModel
            if let vmStatus = viewModel.latestUpdateStatus {
                updateStatus = vmStatus
            }
        }
        .sheet(isPresented: $showDebugInfo) {
            DebugInfoView()
        }
    }
    
    // MARK: - Recording State Menu
    
    private func recordingMenuContent(session: RecordingSession) -> some View {
        Group {
            // Recording status indicator
            HStack {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("Recording (\(session.elapsedTimeString))")
            }
            
            // Show audio source (app name or "All System Audio")
            Text("Capturing: \(session.audioSourceDescription)")
                .foregroundStyle(.secondary)
            
            Button("Stop Recording") {
                viewModel.stopRecording(for: session)
            }
            
            Divider()
            
            Button("Show Recording Window") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("o", modifiers: .command)
            
            Divider()
            
            Button("Quit \(appName)") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
