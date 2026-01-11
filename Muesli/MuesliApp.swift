import SwiftUI
import Foundation
import AppKit

@main
struct MuesliApp: App {
    @State private var viewModel: MuesliViewModel
    @State private var preferencesManager: PreferencesManager
    @State private var meetingHistoryManager: MeetingHistoryManager
    @State private var permissionManager: PermissionManager
    @State private var refinementCoordinator: RefinementCoordinator
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Create managers in dependency order
        let prefs = PreferencesManager()
        let historyManager = MeetingHistoryManager()
        let permManager = PermissionManager()

        // Create refinement coordinator with dependencies
        // Note: ViewModel also creates its own LLMManager, so we need to share the same one
        let llmManager = LLMManager()
        let fileOutputService = FileOutputService()
        let coordinator = RefinementCoordinator(llmManager: llmManager, fileOutputService: fileOutputService)

        // Create ViewModel with injected managers
        // This ensures ViewModel shares the same state with the managers
        let vm = MuesliViewModel(
            preferencesManager: prefs,
            historyManager: historyManager,
            refinementCoordinator: coordinator
        )

        // Wire up PreferencesManager callbacks to services
        prefs.outputDirectoryDidChange = { newDirectory in
            fileOutputService.setOutputDirectory(newDirectory)
        }
        prefs.transcriptionModeDidChange = { newMode in
            // Now that ViewModel delegates to preferencesManager, this callback
            // is for external services that need to react to transcription mode changes
            vm.transcriptionMode = newMode.serviceMode
        }

        // Initialize @State properties
        _viewModel = State(initialValue: vm)
        _preferencesManager = State(initialValue: prefs)
        _meetingHistoryManager = State(initialValue: historyManager)
        _permissionManager = State(initialValue: permManager)
        _refinementCoordinator = State(initialValue: coordinator)
    }
    
    var body: some Scene {
        // Menu bar dropdown - always available
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
                .environment(meetingHistoryManager)
                .environment(refinementCoordinator)
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
                    .environment(refinementCoordinator)
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
                .environment(refinementCoordinator)
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
    
    /// Called when onboarding completes - opens main window and closes onboarding window
    func completeOnboarding() {
        // Close the onboarding window first
        onboardingWindow?.close()
        onboardingWindow = nil
        onboardingViewModel = nil
        
        // Ensure UserDefaults is synced
        UserDefaults.standard.synchronize()
        
        // Use NSWorkspace to open the main window
        // This ensures SwiftUI creates the window if it doesn't exist
        Task { @MainActor in
            // Small delay to ensure window system is ready
            try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
            
            // Activate the app
            NSApplication.shared.activate(ignoringOtherApps: true)
            
            // Find or create the main window
            // SwiftUI Window scenes create windows automatically, but we need to trigger it
            // by using the openWindow environment value or by finding the window scene
            
            // First, try to find existing main window
            var mainWindow = NSApplication.shared.windows.first(where: { window in
                // Check window identifier (SwiftUI sets this for Window scenes)
                if let identifier = window.identifier?.rawValue, identifier == "main" {
                    return true
                }
                // Also check by content view type as fallback
                if window.contentViewController is NSHostingController<MainWindowView> {
                    return true
                }
                return false
            })
            
            // If window doesn't exist, we need to trigger SwiftUI to create it
            // Since we're using Window (not WindowGroup), SwiftUI should create it on first access
            // We can trigger this by posting a notification that the app should open the main window
            if mainWindow == nil {
                // Post notification to trigger window creation
                // The MuesliApp's Window scene should respond to this
                NotificationCenter.default.post(
                    name: NSNotification.Name("NSApplicationDidFinishLaunching"),
                    object: NSApplication.shared
                )
                
                // Wait a bit for SwiftUI to create the window
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                
                // Check again
                mainWindow = NSApplication.shared.windows.first(where: { window in
                    if let identifier = window.identifier?.rawValue, identifier == "main" {
                        return true
                    }
                    if window.contentViewController is NSHostingController<MainWindowView> {
                        return true
                    }
                    return false
                })
            }
            
            // Show the main window
            if let window = mainWindow {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            } else {
                // Last resort: log and try to open via menu bar
                print("[AppDelegate] Warning: Main window not found. Attempting to open via menu...")
                // The menu bar should have an option to open the main window
            }
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

