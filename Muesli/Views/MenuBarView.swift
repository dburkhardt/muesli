import SwiftUI

/// Content for the menu bar dropdown
struct MenuBarView: View {
    let viewModel: MuesliViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    
    /// Use @AppStorage so SwiftUI automatically observes UserDefaults changes
    @AppStorage(AppStorageKeys.hasCompletedOnboarding) private var hasCompletedOnboarding: Bool = false
    
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
    
    // MARK: - Onboarding State Menu
    
    private var onboardingMenuContent: some View {
        Group {
            Button("Resume Set Up") {
                AppDelegate.shared?.bringOnboardingWindowToFront()
            }
            
            Divider()
            
            Button("Quit \(appName)") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
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
            
            Divider()
            
            Button("Quit \(appName)") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
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
