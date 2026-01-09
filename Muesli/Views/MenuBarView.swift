import SwiftUI

/// Content for the menu bar dropdown
struct MenuBarView: View {
    let viewModel: MuesliViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    
    var body: some View {
        Group {
            // WorkTree identifier header (if applicable)
            if let suffix = WorkTreeIdentifier.workTreeSuffix {
                Text("WorkTree: \(suffix)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .disabled(true)
                
                Divider()
            }
            
            if let activeSession = viewModel.activeSession, activeSession.isRecording {
                recordingMenuContent(session: activeSession)
            } else {
                idleMenuContent
            }
        }
    }
    
    // MARK: - Idle State Menu
    
    private var idleMenuContent: some View {
        Group {
            // Quick start recording (captures all system audio)
            // Only show if onboarding is complete
            if viewModel.hasCompletedOnboarding {
                Button("Start Recording") {
                    viewModel.quickStartRecording()
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            
            Divider()
            
            Button("Open Muesli") {
                // If onboarding not complete, show onboarding window instead
                if !viewModel.hasCompletedOnboarding {
                    // Find and bring onboarding window to front
                    if let onboardingWindow = NSApplication.shared.windows.first(where: { $0.title == "Welcome to Muesli" }) {
                        onboardingWindow.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    } else {
                        // Window doesn't exist, trigger AppDelegate to create it
                        // Post notification that AppDelegate can listen to
                        NotificationCenter.default.post(name: NSNotification.Name("ShowOnboardingWindow"), object: nil)
                    }
                } else {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            .keyboardShortcut("o", modifiers: .command)
            
            Divider()
            
            Button("Preferences...") {
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            
            Divider()
            
            Button("Quit Muesli") {
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
            
            Button("Quit Muesli") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
