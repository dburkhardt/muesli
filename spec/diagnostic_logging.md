# Diagnostic Logging Specification

This document specifies Muesli's diagnostic logging system, a **required** infrastructure component that ships with all builds (Debug and Release) to aid debugging of release-specific issues.

## Overview

The diagnostic logging system writes structured, human-readable logs to disk for debugging issues that only appear in release builds (e.g., permission prompts, entitlement issues, Info.plist problems). Unlike `os.log` which requires Console.app and doesn't persist reliably, diagnostic logs are plain text files accessible via Finder, Terminal, or any text editor.

## Why Diagnostic Logging is Required

1. **Release-only bugs**: Some issues only appear in production builds due to code signing, notarization, or optimization differences
2. **30+ minute build cycles**: DMG creation is slow; we need logs that persist across reinstalls
3. **User debugging**: Users can share log files for bug reports without special tools
4. **Event history**: Logs capture the sequence of events leading to a problem

## Architecture

### DiagnosticLogger Actor

The core logging component is a Swift actor for thread-safe file operations:

```swift
actor DiagnosticLogger {
    static let shared = DiagnosticLogger()
    
    enum Category: String {
        case permission = "PERMISSION"
        case onboarding = "ONBOARDING"
        case build = "BUILD"
        case app = "APP"
        case transcription = "TRANSCRIPTION"
        case aec = "AEC"
    }

    func log(_ category: Category, _ message: String)
    func logBuildInfo()
}
```

> **Note**: `log()` and `logBuildInfo()` are synchronous from the caller's perspective. Since `DiagnosticLogger` is an actor, any actor hop is internal to the implementation — callers simply `await` the result without needing to mark their own functions `async` solely for logging.

**Location**: `Muesli/Utilities/DiagnosticLogger.swift`

### Log Categories

| Category | Purpose | Example Messages |
|----------|---------|------------------|
| `BUILD` | Bundle ID, version, Info.plist keys | "Bundle: com.muesli.app, Version: 0.1.2" |
| `PERMISSION` | Permission checks and requests | "authorizationStatus(for: .audio) = 0 (notDetermined)" |
| `ONBOARDING` | Step transitions, button taps | "Grant Microphone Access button tapped" |
| `APP` | General app lifecycle events | "App launched", "Recording started" |
| `TRANSCRIPTION` | WhisperKit transcription events, model selection, segment timing | "Model loaded: openai_whisper-base", "Segment 12: 3.2s" |
| `AEC` | Echo cancellation pipeline events, mode switches, calibration | "AEC mode: voiceProcessing", "Calibration complete" |

### BuildInfo Struct

The `BuildInfo` struct captures build-time metadata, logged at app launch via `logBuildInfo()`. Fields are populated by a build script that generates `BuildInfo.swift` on every build.

| Field | Type | Description |
|-------|------|-------------|
| `gitCommit` | `String` | Short git commit hash |
| `gitBranch` | `String` | Current branch name |
| `isDirty` | `Bool` | Whether working tree has uncommitted changes |
| `buildType` | `String` | Debug or Release |
| `buildTimestamp` | `String` | UTC ISO 8601 build timestamp |
| `isCIBuild` | `Bool` | Whether built in CI environment |
| `ciRunInfo` | `String?` | CI run ID / info if available |

## Log File Management

### Location

```
~/Library/Application Support/Muesli/Logs/
```

### File Naming

- **Format**: `muesli-YYYY-MM-DD.log`
- **One file per day**: Automatic rotation at midnight
- **Example**: `muesli-2026-01-20.log`

### Retention Policy

- **Keep**: Last 7 days of logs
- **Cleanup**: On app launch, delete files older than 7 days
- **Size limit**: 10MB per file (stop writing if exceeded; fresh file next day)

### Log Format

Plain text, grep-friendly:

```
[2026-01-20 14:30:45.123] [PERMISSION] requestMicrophonePermission called. Bundle: com.muesli.app
[2026-01-20 14:30:45.124] [PERMISSION] NSMicrophoneUsageDescription: Muesli needs Microphone access...
[2026-01-20 14:30:45.125] [PERMISSION] authorizationStatus(for: .audio) = 0 (notDetermined)
[2026-01-20 14:30:45.126] [PERMISSION] Status is notDetermined, calling requestAccess...
[2026-01-20 14:30:47.890] [PERMISSION] requestAccess returned: true
```

## Privacy Policy (STRICT)

Diagnostic logs contain **only** build/permission metadata. No user content.

### Allowed to Log

- Bundle ID, app version, build configuration
- Permission states (raw enum values)
- Info.plist keys and their presence/absence
- Onboarding step numbers
- Button tap events (by name, e.g., "Grant Microphone Access tapped")
- Method entry/exit with status codes
- Timestamps

### NEVER Log

- Transcript content or snippets
- Meeting titles or file names
- User file paths outside Application Support
- Audio data or waveform information
- App selection history (which meeting apps user has)
- Any personally identifiable information

**Enforcement**: Code review. All `DiagnosticLogger.log()` calls must be auditable.

## Debug Info Panel

A user-accessible panel displays diagnostic information and provides access to logs.

**Location**: `Muesli/Views/DebugInfoView.swift`

### Access

- **Menu Bar** → "Debug Info..." (available in BOTH idle and onboarding menus)
- Always visible (early-stage project; revisit before major public release)

### Displayed Information

| Field | Source | Notes |
|-------|--------|-------|
| Bundle ID | `Bundle.main.bundleIdentifier` | |
| App Version | `Bundle.main.infoDictionary` | |
| Build Config | `#if DEBUG` | Debug or Release |
| Microphone Status | `AVCaptureDevice.authorizationStatus(for: .audio)` | Raw int (0-3) |
| Screen Recording Status | `CGPreflightScreenCaptureAccess()` | "(may be unreliable with ad-hoc signing)" |
| Onboarding State | Current step, `hasCompletedOnboarding` | |
| NSMicrophoneUsageDescription | `Bundle.main.object(forInfoDictionaryKey:)` | Or "MISSING" |
| NSScreenCaptureUsageDescription | `Bundle.main.object(forInfoDictionaryKey:)` | Or "MISSING" |
| NSAudioCaptureUsageDescription | `Bundle.main.object(forInfoDictionaryKey:)` | Or "MISSING" (not yet displayed by actual view — marks intended state) |
| Log File Location | Path to logs directory | |

### Actions

- **"Open in Finder"**: Opens logs directory in Finder
- **"Copy All"**: Copies all diagnostic info to clipboard

### Safety

- **NEVER call `SCShareableContent`** from DebugInfoView - triggers permission prompt
- Use cached permission values only

## Integration Points

### App Launch

In `MuesliApp.swift`, call `logBuildInfo()` on app launch:

```swift
@main
struct MuesliApp: App {
    init() {
        Task {
            await DiagnosticLogger.shared.logBuildInfo()
        }
    }
}
```

### Permission Manager

Add logging to all permission checks and requests:

```swift
func requestMicrophonePermission() async -> Bool {
    await DiagnosticLogger.shared.log(.permission, 
        "requestMicrophonePermission called. Bundle: \(bundleID)")
    
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    await DiagnosticLogger.shared.log(.permission, 
        "authorizationStatus(for: .audio) = \(status.rawValue)")
    
    // ... rest of implementation
}
```

### Onboarding View

Log step transitions and button taps:

```swift
Button("Grant Microphone Access") {
    Task {
        await DiagnosticLogger.shared.log(.onboarding, 
            "Grant Microphone Access button tapped")
    }
    // ... rest of handler
}
```

## Accessing Logs

### From Terminal

```bash
# View today's log
cat ~/Library/Application\ Support/Muesli/Logs/muesli-$(date +%Y-%m-%d).log

# Search for permission-related entries
grep PERMISSION ~/Library/Application\ Support/Muesli/Logs/*.log

# Watch log in real-time
tail -f ~/Library/Application\ Support/Muesli/Logs/muesli-$(date +%Y-%m-%d).log

# Search for specific events
grep "Grant Microphone Access" ~/Library/Application\ Support/Muesli/Logs/*.log
```

### From Debug Info Panel

1. Menu Bar → "Debug Info..."
2. Click "Open in Finder"
3. Open log file in any text editor

## Expected Log Output

### Successful Permission Grant

```
[2026-01-20 14:30:45] [PERMISSION] requestMicrophonePermission called. Bundle: com.muesli.app
[2026-01-20 14:30:45] [PERMISSION] NSMicrophoneUsageDescription: Muesli needs Microphone access...
[2026-01-20 14:30:45] [PERMISSION] authorizationStatus(for: .audio) = 0 (notDetermined)
[2026-01-20 14:30:45] [PERMISSION] Status is notDetermined, calling requestAccess...
[2026-01-20 14:30:47] [PERMISSION] requestAccess returned: true
```

### Missing Info.plist Key

```
[2026-01-20 14:30:45] [PERMISSION] requestMicrophonePermission called. Bundle: com.muesli.app
[2026-01-20 14:30:45] [PERMISSION] NSMicrophoneUsageDescription: MISSING
```

### Button Handler Not Executing

If logs show no entries after button tap, the tap handler isn't being called (SwiftUI issue).

### Permission Already Denied

```
[2026-01-20 14:30:45] [PERMISSION] authorizationStatus(for: .audio) = 2 (denied)
[2026-01-20 14:30:45] [PERMISSION] Status is denied/restricted, returning false (no prompt possible)
```

## Files

| File | Purpose |
|------|---------|
| `Muesli/Utilities/DiagnosticLogger.swift` | Core logging actor |
| `Muesli/Views/DebugInfoView.swift` | Debug info panel UI |
| `Muesli/Views/MenuBarView.swift` | Menu item for Debug Info |

## Best Practices

- **System audio permission model**: The app uses a tap-probe at session start rather than calling `CGPreflightScreenCaptureAccess()` as a preflight. The result is cached in `UserDefaults` so subsequent checks avoid re-probing.
- **RT audio callback constraints**: Real-time audio callbacks (e.g., `IOProc`) must not perform heap allocation, Objective-C messaging, or lock acquisition. Log from RT callbacks only via lock-free ring buffers or deferred dispatch.
- **WhisperKit sample rate**: WhisperKit requires 16 kHz mono audio. Always resample from the 48 kHz capture rate using `TranscriptionService.resampleToWhisperFormat()`.
- **macOS version requirement**: `AudioHardwareCreateProcessTap` is available on macOS 14.2+. The app requires macOS 14.2 or later for system audio capture.

## Testing

### Verify Logging Works

1. Build app: `./scripts/build-and-launch.sh`
2. Open Debug Info panel from menu bar
3. Verify all fields populate correctly
4. Click "Open in Finder"
5. Verify log file exists with build info

### Verify Privacy Policy

1. Search logs for transcript content: `grep -i "transcript content" ~/Library/Application\ Support/Muesli/Logs/*.log`
2. Search for file paths: `grep -E "/Users/[^/]+/" ~/Library/Application\ Support/Muesli/Logs/*.log`
3. Both should return empty results

## Future Considerations

- **Debug UI visibility**: Currently always visible. Consider hiding behind Option-key modifier or Preferences toggle before major public release.
- **Log upload**: Could add optional log upload for debugging with user consent
- **Consolidation**: If codebase grows, consider single logging facade that writes to both `os.log` and `DiagnosticLogger`
