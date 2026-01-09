# Merge Notes: bugfix/onboarding-bypass

## Purpose
This branch fixes the onboarding bypass bug where users could skip onboarding by clicking "Start Recording" or "Open Muesli" from the menu bar.

## Commits to Merge (cherry-pick recommended)
Only these commits contain the actual bug fix:
- `35eb881` - Fix onboarding bypass bug
- `7f8b1c4` - Configure worktree app identity: ayb (DO NOT MERGE - worktree-specific)

**Recommendation**: Cherry-pick only `35eb881` to main.

## Merge Conflicts Expected

### 1. `Muesli/MuesliApp.swift` - HIGH CONFLICT PROBABILITY

**Main's current implementation:**
- Has `WindowOpener` class for opening windows
- Uses `NotificationCenter` with `"ShowOnboardingWindow"` notification
- `showOnboardingWindow()` is public and checks for existing windows
- Has full menu bar commands (File menu, Window menu, Help menu, About window)

**This branch's implementation:**
- Removed `WindowOpener` class (simpler approach)
- Added `static var shared: AppDelegate?` for direct access
- `showOnboardingWindow()` is private
- Added `bringOnboardingWindowToFront()` method
- No menu bar commands (simplified)

**Resolution approach:**
Keep main's structure but add the `AppDelegate.shared` pattern:
```swift
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?  // ADD THIS
    
    // ... existing code ...
    
    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            AppDelegate.shared = self  // ADD THIS
            // ... existing notification observer setup ...
        }
        // ... rest of existing code ...
    }
    
    // Keep showOnboardingWindow() as-is (public)
    
    // ADD this new method:
    func bringOnboardingWindowToFront() {
        showOnboardingWindow()  // Can reuse existing method since it already handles "window exists" case
    }
}
```

### 2. `Muesli/Views/MenuBarView.swift` - HIGH CONFLICT PROBABILITY

**Main's current implementation:**
- Has `WorkTreeIdentifier` header display
- Conditionally hides "Start Recording" button during onboarding
- "Open Muesli" has inline logic to redirect to onboarding window via notification

**This branch's implementation:**
- Removed `WorkTreeIdentifier` display
- Added `hasCompletedOnboarding` computed property
- Added separate `onboardingMenuContent` view (simplified menu)
- Shows ONLY "Resume Set Up" + "Quit" during onboarding

**Resolution approach:**
Add the `onboardingMenuContent` to main's version:

```swift
struct MenuBarView: View {
    // ... existing properties ...
    
    private var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    }
    
    var body: some View {
        Group {
            // Keep WorkTreeIdentifier header if desired
            if let suffix = WorkTreeIdentifier.workTreeSuffix {
                Text("WorkTree: \(suffix)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .disabled(true)
                Divider()
            }
            
            // ADD THIS CHECK - show simplified menu during onboarding
            if !hasCompletedOnboarding {
                onboardingMenuContent
            } else if let activeSession = viewModel.activeSession, activeSession.isRecording {
                recordingMenuContent(session: activeSession)
            } else {
                idleMenuContent
            }
        }
    }
    
    // ADD this new view:
    private var onboardingMenuContent: some View {
        Group {
            Button("Resume Set Up") {
                AppDelegate.shared?.bringOnboardingWindowToFront()
            }
            
            Divider()
            
            Button("Quit Muesli") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
    
    // Keep existing idleMenuContent and recordingMenuContent as-is
    // (can remove the inline onboarding checks since we handle it at top level)
}
```

### 3. `Muesli.xcodeproj/project.pbxproj` - DO NOT MERGE

This file contains worktree-specific configuration:
- Bundle ID: `com.muesli.app.ayb` (should remain `com.muesli.app` on main)
- Product name: `Muesli-ayb` (should remain `Muesli` on main)
- TCC reset script references `com.muesli.app.ayb`

**Resolution**: Reject all changes from this branch for this file.

## Files That Should NOT Be Merged
- `Muesli.xcodeproj/project.pbxproj` - Contains worktree-specific bundle ID
- `package-lock.json` - Unrelated change

## Testing After Merge
1. Build the app fresh (UserDefaults will be reset)
2. Verify menu bar shows only "Resume Set Up" and "Quit Muesli" during onboarding
3. Click "Resume Set Up" - should bring onboarding window to front
4. Complete onboarding
5. Verify full menu appears after onboarding completion
6. Verify "Start Recording" and "Open Muesli" work normally

## Summary of Changes Needed on Main
1. Add `static var shared: AppDelegate?` to `AppDelegate`
2. Set `AppDelegate.shared = self` in `applicationDidFinishLaunching`
3. Add `bringOnboardingWindowToFront()` method to `AppDelegate`
4. Add `hasCompletedOnboarding` computed property to `MenuBarView`
5. Add `onboardingMenuContent` view to `MenuBarView`
6. Update `MenuBarView.body` to show `onboardingMenuContent` when `!hasCompletedOnboarding`
