# Window Management Specification

This document specifies how Muesli manages its windows, particularly the interaction between the main window, onboarding window, and SwiftUI's automatic window creation.

## Overview

Muesli uses a hybrid window architecture:
1. **Main Window**: SwiftUI `Window` scene (auto-created by SwiftUI)
2. **Onboarding Window**: NSWindow created programmatically by AppDelegate
3. **Menu Bar**: SwiftUI `MenuBarExtra` (always available)
4. **Other Windows**: SwiftUI `WindowGroup` scenes (on-demand)

## The Window Auto-Creation Problem

### Problem Statement
SwiftUI's `Window` scene type automatically creates and displays its window when the app launches. This conflicts with the onboarding flow, which should be the ONLY window visible until the user completes setup.

### Root Cause
```swift
// This Window scene is auto-shown by SwiftUI on app launch
Window(Self.appDisplayName, id: "main") {
    MainWindowView(viewModel: viewModel)
}
```

SwiftUI creates the window instance as part of scene initialization, and displays it as the app's primary content. The `AppDelegate.applicationDidFinishLaunching` runs AFTER this automatic window creation.

### Solution
The `AppDelegate.showOnboardingWindow()` method must:
1. Hide the main window immediately before showing onboarding
2. Use `window.orderOut(nil)` to hide without destroying the window
3. The main window is re-shown when `completeOnboarding()` is called

```swift
private func showOnboardingWindow() {
    // CRITICAL: Hide the main window during onboarding
    hideMainWindow()
    
    // ... create and show onboarding window ...
}

private func hideMainWindow() {
    for window in NSApplication.shared.windows {
        if let identifier = window.identifier?.rawValue, identifier == "main" {
            window.orderOut(nil)
            break
        }
    }
}
```

## Window Lifecycle

### First Launch (Onboarding Required)

```
┌─────────────────────────────────────────────────────────────────┐
│                         APP LAUNCH                               │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│              SwiftUI auto-creates main window                    │
│              (Window scene initializes)                          │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│           applicationDidFinishLaunching called                   │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
                    ┌───────────────────────┐
                    │ hasCompletedOnboarding│
                    │      == false         │
                    └───────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│          showOnboardingWindow() called:                          │
│          1. hideMainWindow() - hides auto-created window         │
│          2. Create NSWindow with OnboardingView                  │
│          3. Show onboarding window                               │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
                    ┌───────────────────────┐
                    │  User completes       │
                    │  onboarding flow      │
                    └───────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│          completeOnboarding() called:                            │
│          1. Close onboarding window                              │
│          2. Set hasCompletedOnboarding = true                    │
│          3. Find and show main window                            │
└─────────────────────────────────────────────────────────────────┘
```

### Subsequent Launch (Onboarding Complete)

```
┌─────────────────────────────────────────────────────────────────┐
│                         APP LAUNCH                               │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│              SwiftUI auto-creates main window                    │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│           applicationDidFinishLaunching called                   │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
                    ┌───────────────────────┐
                    │ hasCompletedOnboarding│
                    │      == true          │
                    └───────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│          Main window stays visible (no action needed)            │
│          (May call makeKeyAndOrderFront for focus)               │
└─────────────────────────────────────────────────────────────────┘
```

## Window Types

| Window | Scene Type | Creation | Visibility Control |
|--------|------------|----------|-------------------|
| Main | `Window` | Auto by SwiftUI | Hide during onboarding |
| Onboarding | `NSWindow` | Manual by AppDelegate | Show on first launch |
| Model Management | `WindowGroup` | On-demand via openWindow | openWindow(id:) |
| Completed Meeting | `WindowGroup` | On-demand via openWindow | openWindow(id:) |
| Preferences | `Settings` | Cmd+, | System managed |

## Key Implementation Details

### Window Identification
SwiftUI sets window identifiers from the scene's `id` parameter:
```swift
Window(Self.appDisplayName, id: "main")  // Creates window with identifier "main"
```

### Finding Windows by Identifier
```swift
NSApplication.shared.windows.first(where: { 
    $0.identifier?.rawValue == "main" 
})
```

### Hiding vs Closing
- `window.orderOut(nil)` - Hides window but keeps it in memory
- `window.close()` - Closes and may deallocate (depending on `isReleasedWhenClosed`)

Use `orderOut` for the main window to preserve SwiftUI state.

## Regression Test Cases

### Test: Main Window Hidden During Onboarding
- Reset `hasCompletedOnboarding` to false
- Launch app
- Verify ONLY onboarding window is visible
- Main window should NOT be visible

### Test: Main Window Shows After Onboarding
- Complete onboarding flow
- Verify main window appears
- Verify onboarding window is closed

### Test: Main Window Visible on Subsequent Launch
- With `hasCompletedOnboarding = true`, launch app
- Verify main window is visible
- Verify NO onboarding window appears

### Test: Window Identifier Consistency
- Launch app
- Verify main window has identifier "main"
- This ensures the hiding logic can find the correct window

## Known Issues and Mitigations

### Issue: Race Condition on Launch
SwiftUI may show the main window briefly before `applicationDidFinishLaunching` runs.

**Mitigation**: The `hideMainWindow()` call in `showOnboardingWindow()` handles this by explicitly hiding any already-visible main window.

### Issue: Multiple Window Instances
`WindowGroup` can create multiple instances. `Window` creates exactly one.

**Mitigation**: Use `Window` (not `WindowGroup`) for the main window to ensure single instance.

## Key Files

| File | Responsibility |
|------|----------------|
| `MuesliApp.swift` | Scene definitions, AppDelegate |
| `AppDelegate` (in MuesliApp.swift) | Window lifecycle management |
| `MainWindowView.swift` | Main window content |
| `OnboardingView.swift` | Onboarding content |

## Change History

| Date | Change | Reason |
|------|--------|--------|
| 2026-01-15 | Added hideMainWindow() to showOnboardingWindow() | Fix main window appearing during onboarding |
