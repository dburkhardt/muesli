import SwiftUI
import Foundation
import AppKit

/// Helper to open windows from menu commands
@MainActor
final class WindowOpener: ObservableObject {
    weak var appDelegate: AppDelegate?
    
    func openWindow(id: String, viewModel: MuesliViewModel) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        // If trying to open main window during onboarding, show onboarding instead
        if id == "main" && !viewModel.hasCompletedOnboarding {
            // Bring onboarding window to front
            appDelegate?.showOnboardingWindow()
            return
        }
        
        // For WindowGroup scenes, we need to trigger window creation
        // SwiftUI will handle this automatically when the window is accessed
        if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == id }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // For Window scenes (like "main"), they're always available
            // For WindowGroup scenes, trigger creation via notification or delay
            Task {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == id }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
    }
}

@main
struct MuesliApp: App {
    @State private var viewModel = MuesliViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var windowOpener = WindowOpener()
    
    var body: some Scene {
        // Menu bar dropdown - always available
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
        } label: {
            MenuBarIconView()
        }
        
        // NOTE: Onboarding is handled by AppDelegate.showOnboardingWindow()
        // Removed duplicate WindowGroup that was creating separate ViewModel
        
        // Model management window
        WindowGroup("Manage Transcription Models", id: "modelManagement") {
            ModelManagementView(viewModel: viewModel)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        
        // Completed meeting window (for viewing while recording)
        WindowGroup("Meeting Transcript", id: "completedMeeting") {
            if let meeting = viewModel.completedMeetingWindowItem {
                CompletedMeetingWindow(meeting: meeting, viewModel: viewModel)
            } else {
                Text("No meeting selected")
                    .frame(width: 600, height: 500)
            }
        }
        .defaultSize(width: 600, height: 500)
        .windowResizability(.contentSize)
        
        // Main window - SINGLE window for recordings (not WindowGroup)
        Window("Muesli", id: "main") {
            MainWindowView(viewModel: viewModel)
        }
        .defaultSize(width: 420, height: 600)
        .windowResizability(.contentSize)
        
        // Preferences window - accessible via Cmd+,
        Settings {
            PreferencesView(viewModel: viewModel)
        }
        .commands {
            // Muesli menu (Application menu)
            CommandGroup(replacing: .appInfo) {
                Button("About Muesli") {
                    viewModel.showAbout()
                    windowOpener.openWindow(id: "about", viewModel: viewModel)
                }
            }
            
            CommandGroup(after: .appInfo) {
                Divider()
                Button("Preferences...") {
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            
            // File menu
            CommandMenu("File") {
                if let activeSession = viewModel.activeSession, activeSession.isRecording {
                    Button("Stop Recording") {
                        viewModel.stopRecording(for: activeSession)
                    }
                    Divider()
                } else if viewModel.hasCompletedOnboarding {
                    // Only show "New Recording" if onboarding is complete
                    Button("New Recording") {
                        viewModel.startNewRecording()
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    Divider()
                }
                
                Button("Open Muesli") {
                    windowOpener.openWindow(id: "main", viewModel: viewModel)
                }
                .keyboardShortcut("o", modifiers: .command)
                
                Divider()
                
                Button("Close Window") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            
            // Window menu - use standard window management
            CommandGroup(replacing: .windowList) {
                if viewModel.hasCompletedOnboarding {
                    Button("Main Window") {
                        windowOpener.openWindow(id: "main", viewModel: viewModel)
                    }
                    .keyboardShortcut("1", modifiers: .command)
                }
            }
            
            // Help menu
            CommandGroup(replacing: .help) {
                Button("Muesli Help") {
                    // TODO: Open help documentation
                    if let url = URL(string: "https://github.com/yourusername/muesli") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }
        
        // About window
        Window("About Muesli", id: "about") {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultSize(width: 400, height: 500)
    }
}

/// App delegate that opens onboarding window on first launch
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var onboardingWindow: NSWindow?
    private var onboardingViewModel: MuesliViewModel?
    
    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        // Set up notification observer for showing onboarding window
        Task { @MainActor in
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name("ShowOnboardingWindow"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.showOnboardingWindow()
            }
        }
        
        // Check if onboarding is needed
        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            Task { @MainActor in
                self.showOnboardingWindow()
            }
        } else {
            // Open main window if onboarding is complete
            Task { @MainActor in
                // Small delay to ensure window system is ready
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                NSApplication.shared.activate(ignoringOtherApps: true)
                if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
    }
    
    func showOnboardingWindow() {
        // If onboarding window already exists, just bring it to front
        if let existingWindow = onboardingWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        // Also check if there's already an onboarding window by title
        if let existingWindow = NSApplication.shared.windows.first(where: { $0.title == "Welcome to Muesli" }) {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.onboardingWindow = existingWindow
            return
        }
        
        // Create the onboarding window manually
        let viewModel = MuesliViewModel()
        self.onboardingViewModel = viewModel
        let onboardingView = OnboardingView(viewModel: viewModel)
        
        let hostingController = NSHostingController(rootView: onboardingView)
        
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Welcome to Muesli"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 500, height: 450))
        window.center()
        window.isReleasedWhenClosed = false
        
        self.onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Custom view for menu bar icon that uses template rendering for light/dark mode adaptation
struct MenuBarIconView: View {
    var body: some View {
        Image(nsImage: createMenuBarIcon())
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 16, height: 16)
    }
    
    private func createMenuBarIcon() -> NSImage {
        guard let sourceImage = NSImage(named: "MenuBarIcon") else {
            return NSImage()
        }
        
        // Use template rendering so icon adapts to light/dark mode
        // Icon should have black pixels on transparent background
        sourceImage.isTemplate = true
        
        return sourceImage
    }
}

