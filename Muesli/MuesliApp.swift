import SwiftUI
import Foundation
import AppKit

@main
struct MuesliApp: App {
    @State private var viewModel = MuesliViewModel()
    @State private var preferencesManager = PreferencesManager()
    @State private var meetingHistoryManager = MeetingHistoryManager()
    @State private var permissionManager = PermissionManager()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    
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
            if let meeting = meetingHistoryManager.completedMeetingWindowItem {
                CompletedMeetingWindow(meeting: meeting, viewModel: viewModel)
                    .environment(meetingHistoryManager)
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
                .environment(meetingHistoryManager)
                .environment(permissionManager)
        }
        .defaultSize(width: 420, height: 600)
        .windowResizability(.contentSize)
        
        // Preferences window - accessible via Cmd+,
        Settings {
            PreferencesView(viewModel: viewModel)
                .environment(preferencesManager)
        }
    }
}

/// App delegate that opens onboarding window on first launch
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    private var onboardingWindow: NSWindow?
    private var onboardingViewModel: MuesliViewModel?
    
    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            AppDelegate.shared = self
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
    
    private func showOnboardingWindow() {
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
    
    /// Brings onboarding window to front, or creates one if it doesn't exist
    func bringOnboardingWindowToFront() {
        if let window = onboardingWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            showOnboardingWindow()
        }
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

