import AppKit
import AVFoundation
import Foundation
import os.log
import SwiftUI

@main
struct MuesliApp: App {
    // MARK: - Logging
    
    // Use nonisolated logger since it's accessed from App Delegate
    nonisolated(unsafe) static let logger = Logger(subsystem: "com.muesli.app", category: "MuesliApp")
    
    @State private var viewModel: MuesliViewModel
    @State private var preferencesManager: PreferencesManager
    @State private var meetingHistoryManager: MeetingHistoryManager
    @State private var permissionManager: PermissionManager
    @State private var refinementCoordinator: RefinementCoordinator
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    
    /// Get the app's display name from the bundle (e.g., "Muesli" or "Muesli-feature-xyz")
    static var appDisplayName: String {
        Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Muesli"
    }
    
    /// Shared ViewModel instance for the entire app (including onboarding)
    static var sharedViewModel: MuesliViewModel?

    /// Stored openWindow action, captured eagerly from the App body getter
    /// so AppDelegate can reopen the main window without SwiftUI Environment access.
    @MainActor private static var _openWindow: OpenWindowAction?

    /// Set when openMainWindow() is called before SwiftUI's body has been
    /// evaluated (i.e. _openWindow is still nil).  installOpenWindowCallback()
    /// drains this flag as soon as the action becomes available.
    @MainActor private static var _pendingMainWindowOpen = false

    @MainActor static func installOpenWindowCallback(_ action: OpenWindowAction) {
        _openWindow = action
        if _pendingMainWindowOpen {
            _pendingMainWindowOpen = false
            logger.info("Fulfilling deferred openMainWindow request")
            openMainWindow()
        }
    }

    @MainActor static func openMainWindow() {
        guard let action = _openWindow else {
            logger.warning("openMainWindow: _openWindow not yet available — deferring until body is evaluated")
            _pendingMainWindowOpen = true
            return
        }
        action(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    init() {
        // Create managers in dependency order
        let prefs = PreferencesManager()
        let historyManager = MeetingHistoryManager()
        let permManager = PermissionManager()

        // Create services that need to be shared
        let fileOutputService = FileOutputService()
        
        // Create shared LLMManager instance (SINGLE source of truth)
        let llmManager = LLMManager()
        
        // Create refinement coordinator with shared LLMManager
        let coordinator = RefinementCoordinator(llmManager: llmManager, fileOutputService: fileOutputService)

        // Create ViewModel with injected managers and services
        // Pass the shared llmManager to ensure state synchronization
        let vm = MuesliViewModel(
            preferencesManager: prefs,
            historyManager: historyManager,
            refinementCoordinator: coordinator,
            fileOutputService: fileOutputService,
            permissionManager: permManager,
            llmManager: llmManager
        )
        
        // Wire up PreferencesManager callbacks to services
        prefs.outputDirectoryDidChange = { newDirectory in
            fileOutputService.setOutputDirectory(newDirectory)
            historyManager.refreshMeetingHistory()
        }
        // Note: transcriptionModeDidChange callback removed to prevent infinite recursion
        // MuesliViewModel.transcriptionMode setter already updates PreferencesManager AND
        // TranscriptionCoordinator, so no callback needed here

        // Initialize @State properties
        _viewModel = State(initialValue: vm)
        _preferencesManager = State(initialValue: prefs)
        _meetingHistoryManager = State(initialValue: historyManager)
        _permissionManager = State(initialValue: permManager)
        _refinementCoordinator = State(initialValue: coordinator)
        
        // Store shared ViewModel for AppDelegate to access
        MuesliApp.sharedViewModel = vm
    }
    
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        let _ = Self.installOpenWindowCallback(openWindow)

        // Menu bar dropdown - always available
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
                .environment(viewModel)
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
                .environment(viewModel)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Completed meeting window (for viewing while recording)
        WindowGroup("Meeting Transcript", id: "completedMeeting") {
            if let meeting = meetingHistoryManager.completedMeetingWindowItem {
                CompletedMeetingWindow(meeting: meeting, viewModel: viewModel)
                    .environment(viewModel)
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
        Window("", id: "main") {
            MainWindowView(viewModel: viewModel)
                .environment(viewModel)
                .environment(meetingHistoryManager)
                .environment(permissionManager)
                .environment(refinementCoordinator)
        }
        .defaultSize(width: 900, height: 650)
        .windowResizability(.contentSize)

        // Preferences window - accessible via Cmd+,
        Settings {
            PreferencesView(viewModel: viewModel)
                .environment(viewModel)
                .environment(preferencesManager)
        }
        
        // Custom About window (SwiftUI-native approach)
        Window("About \(Self.appDisplayName)", id: "about") {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) {
                NewMeetingMenuButton()
            }

            // Replace the standard About command with our custom one
            CommandGroup(replacing: .appInfo) {
                AboutMenuButton()
            }
        }
    }
}

/// Helper view to access openWindow environment and trigger About window
private struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        Button("About \(MuesliApp.appDisplayName)") {
            openWindow(id: "about")
        }
    }
}

/// File > New command that always reveals the main app window.
private struct NewMeetingMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("n", modifiers: .command)
    }
}

/// App delegate that opens onboarding window on first launch
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    private var onboardingWindow: NSWindow?

    /// Dock click handler: reopen main window (or bring onboarding to front).
    nonisolated func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            if let window = onboardingWindow, window.isVisible {
                bringOnboardingWindowToFront()
                return
            }
            showMainWindow()
        }
        return true
    }

    /// Fallback: when app activates with no visible main window, show it.
    nonisolated func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            let hasVisibleMainWindow = NSApplication.shared.windows.contains {
                $0.identifier?.rawValue == "main" && $0.isVisible
            }
            guard !hasVisibleMainWindow else { return }

            if let window = onboardingWindow, window.isVisible {
                bringOnboardingWindowToFront()
                return
            }

            showMainWindow()
        }
    }
    
    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            AppDelegate.shared = self
            
            // Log build information for diagnostics
            await DiagnosticLogger.shared.logBuildInfo()
        }
        
        // Check for UI testing mode
        let commandLineArgs = ProcessInfo.processInfo.arguments
        let isUITesting = commandLineArgs.contains("-UITestingSkipOnboarding") ||
                         commandLineArgs.contains("-UITestingMockPermissions") ||
                         commandLineArgs.contains("-UITestingUseFixtures") ||
                         commandLineArgs.contains("-UITestingMockModels")
        
        if isUITesting {
            // UI testing mode - handle launch arguments
            Task { @MainActor in
                self.configureUITestingEnvironment()
                
                // Open main window for UI testing
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                NSApplication.shared.activate(ignoringOtherApps: true)
                if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            return
        }
        
        // Check if onboarding is needed
        if !UserDefaults.standard.bool(forKey: AppStorageKeys.hasCompletedOnboarding) {
            Task { @MainActor in
                self.showOnboardingWindow(mode: .firstTime)
            }
        } else {
            // Onboarding complete - check if permissions are still valid
            Task { @MainActor in
                // Check permissions for recovery (fresh check, no cache)
                let (hasTapCached, hasMic) = self.checkPermissionsForRecovery()

                // Log permission check
                await DiagnosticLogger.shared.log(
                    .permission,
                    "Permission check on launch: tapCached=\(hasTapCached), mic=\(hasMic)"
                )

                // Only mic is a hard requirement for recovery mode.
                // Missing tap permission is handled gracefully at recording time
                // (degrades to mic-only mode), so don't block the user.
                if !hasMic {
                    // Log recovery mode trigger
                    await DiagnosticLogger.shared.log(
                        .permission,
                        "Entering permission recovery: missingMic=true"
                    )

                    // Show onboarding for permission recovery (mic only)
                    self.showOnboardingWindow(mode: .permissionRecovery(
                        missingScreen: false,
                        missingMic: true
                    ))
                } else {
                    // Normal launch - open main window
                    // Small delay to ensure window system is ready
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                    self.showMainWindow()
                    
                    // Check for updates after 5 seconds
                    try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                    await MuesliApp.sharedViewModel?.checkForUpdatesOnLaunch()
                }
            }
        }
    }
    
    /// Configure app for UI testing based on launch arguments
    private func configureUITestingEnvironment() {
        let commandLineArgs = ProcessInfo.processInfo.arguments
        
        // Skip onboarding
        if commandLineArgs.contains("-UITestingSkipOnboarding") {
            UserDefaults.standard.set(true, forKey: AppStorageKeys.hasCompletedOnboarding)
        }
        
        // Mock permissions as granted
        if commandLineArgs.contains("-UITestingMockPermissions") {
            // Note: Actual permission mocking would require modifying PermissionManager
            // For now, we mark onboarding as complete
            UserDefaults.standard.set(true, forKey: AppStorageKeys.hasCompletedOnboarding)
        }
        
        // Mock models as available
        if commandLineArgs.contains("-UITestingMockModels") {
            // Set a dummy model path to simulate having models
            UserDefaults.standard.set("tiny", forKey: AppStorageKeys.activeWhisperModel)
        }
        
        // Use fixture data
        if commandLineArgs.contains("-UITestingUseFixtures") {
            // Flag that can be checked by services to return fixture data
            UserDefaults.standard.set(true, forKey: "UITestingUseFixtures")
        }
        
        // Set appearance mode
        if commandLineArgs.contains("-UITestingLightAppearance") {
            NSApp.appearance = NSAppearance(named: .aqua)
        } else if commandLineArgs.contains("-UITestingDarkAppearance") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
    
    private func showOnboardingWindow(mode: AppStorageKeys.OnboardingMode = .firstTime) {
        // Use the shared ViewModel from MuesliApp to ensure state synchronization
        guard let viewModel = MuesliApp.sharedViewModel else {
            MuesliApp.logger.error("Shared ViewModel not available")
            return
        }
        
        // CRITICAL: Hide the main window during onboarding
        // SwiftUI Window scenes automatically create their window on launch,
        // so we need to explicitly hide it when showing onboarding
        hideMainWindow()
        
        let onboardingView = OnboardingView(viewModel: viewModel, mode: mode)
        
        let hostingController = NSHostingController(rootView: onboardingView)
        
        let window = NSWindow(contentViewController: hostingController)
        // Use dynamic app name in window title for first-time, different title for recovery
        let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Muesli"
        window.title = mode.isRecoveryMode ? mode.windowTitle : "Welcome to \(appName)"
        
        // In recovery mode: window is closable (user can dismiss and quit)
        if mode.isRecoveryMode {
            window.styleMask = [.titled, .closable]
        } else {
            window.styleMask = [.titled, .closable]
        }
        
        window.setContentSize(NSSize(width: 520, height: 580))
        window.center()
        window.isReleasedWhenClosed = false
        
        self.onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    /// Check permissions for recovery mode - uses fresh checks, not cached state
    /// CRITICAL: Only uses synchronous, non-prompting APIs
    /// Note: Only mic is a hard requirement. Tap permission is optional — if missing,
    /// the app launches normally and degrades to mic-only at recording time.
    private func checkPermissionsForRecovery() -> (hasTapCached: Bool, hasMic: Bool) {
        // Use cached tap-probe result (consistent with PermissionManager and TapAudioCaptureService).
        // CGPreflightScreenCaptureAccess() checks the wrong TCC bucket (Screen Recording, not System Audio).
        let hasTapCached = UserDefaults.standard.bool(forKey: "systemAudioPermissionGranted")

        // AVCaptureDevice.authorizationStatus() is synchronous and doesn't trigger prompts
        let hasMic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        return (hasTapCached, hasMic)
    }
    
    /// Trigger permission recovery from outside AppDelegate (e.g., ViewModel callback).
    /// Guards against double-show if recovery window is already visible.
    func requestPermissionRecovery(missingScreen: Bool, missingMic: Bool) {
        if let window = onboardingWindow, window.isVisible { return }
        showOnboardingWindow(mode: .permissionRecovery(
            missingScreen: missingScreen,
            missingMic: missingMic
        ))
    }

    /// Called when permission recovery completes - closes onboarding and opens main window
    func exitPermissionRecovery() {
        // Log recovery completion
        Task { @MainActor in
            await DiagnosticLogger.shared.log(
                .permission,
                "Permission recovery completed successfully"
            )
        }
        
        // Close onboarding window
        onboardingWindow?.close()
        onboardingWindow = nil
        
        // Show main window (same as normal launch completion)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
            showMainWindow()
        }
    }
    
    /// Hide the main window (used during onboarding)
    private func hideMainWindow() {
        // Find and hide the main window that SwiftUI auto-creates
        for window in NSApplication.shared.windows {
            if let identifier = window.identifier?.rawValue, identifier == "main" {
                window.orderOut(nil)
                break
            }
        }
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
            self.showMainWindow(existingWindow: mainWindow)
        }
    }

    /// Reveal and activate the main window, creating it via the stored
    /// OpenWindowAction if the NSWindow no longer exists.
    private func showMainWindow(existingWindow: NSWindow? = nil) {
        let mainWindow = existingWindow ?? NSApplication.shared.windows.first(where: { window in
            window.identifier?.rawValue == "main"
        })

        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            mainWindow.orderFrontRegardless()
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        MuesliApp.openMainWindow()
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
