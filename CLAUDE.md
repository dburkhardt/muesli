# Muesli

A local-first meeting transcription app for macOS. Like Granola, but with on-device transcription using WhisperKit.

## Quick Reference

- **Platform**: macOS 14+ (Sonoma)
- **Language**: Swift 6
- **UI Framework**: SwiftUI
- **Architecture**: Single @Observable ViewModel
- **Audio Capture**: ScreenCaptureKit
- **Transcription**: WhisperKit
- **Minimum Deployment**: macOS 14.0
- **Package Manager**: Swift Package Manager

## Build Commands

**IMPORTANT**: Before building, always kill the running Muesli app first:
```bash
killall Muesli
```
Or quit the app from the menu bar. This prevents build failures from trying to overwrite a running executable.

```bash
# Build the project
xcodebuild -scheme Muesli -configuration Debug build

# Run tests
xcodebuild -scheme Muesli -configuration Debug test

# Clean build
xcodebuild -scheme Muesli clean

# Open in Xcode
open Muesli.xcodeproj
```

If XcodeBuildMCP is configured, prefer using MCP tools:
- Build: `mcp__xcodebuildmcp__build`
- Test: `mcp__xcodebuildmcp__test`
- Clean: `mcp__xcodebuildmcp__clean`

**TCC Permissions During Development**: With ad-hoc (debug) code signing, macOS TCC permissions are tied to the code signature hash, which changes on every rebuild. This causes `CGPreflightScreenCaptureAccess()` to return stale results.

**Current Approach**: The project includes a build script that resets TCC permissions on every build:
```bash
# Automatically run before each build (in project.pbxproj)
tccutil reset ScreenCapture com.muesli.app
tccutil reset Microphone com.muesli.app
```

This ensures a clean permission state on each build. The native macOS permission dialogs will appear when needed.

**Manual Reset**: If needed, you can also reset permissions manually with the commands above.

## Project Structure

```
Muesli/
├── MuesliApp.swift              # App entry point, MenuBarExtra + Window scenes
├── Models/
│   ├── MeetingApp.swift         # Data model for detected meeting apps
│   ├── MeetingHistoryItem.swift # Data model for a historical meeting
│   └── RecordingSession.swift   # Data model for an active recording session
├── ViewModels/
│   └── MuesliViewModel.swift    # Main @Observable ViewModel (app state + history)
├── Views/
│   ├── MainWindowView.swift     # Main window container (switches between views)
│   ├── UnifiedHistoryView.swift # Meeting list view (no recording active)
│   ├── MeetingHistorySidebar.swift  # Sidebar with grouped meeting history
│   ├── RecordingDetailView.swift    # Live transcript or completed meeting view
│   ├── StartRecordingSheet.swift    # App picker sheet for new recordings
│   ├── CompletedMeetingWindow.swift # Dedicated window for viewing past meetings
│   ├── MenuBarView.swift        # Menu bar dropdown content
│   ├── OnboardingView.swift     # First-run permissions + model download flow
│   └── Components/              # Reusable UI components
├── Services/
│   ├── AudioCaptureService.swift    # ScreenCaptureKit wrapper
│   ├── MeetingAppDetector.swift     # Detects running meeting apps
│   ├── MeetingHistoryService.swift  # Discovers and loads meeting history from disk
│   ├── TranscriptionService.swift   # WhisperKit wrapper with resampling
│   └── FileOutputService.swift      # Handles saving audio + transcript
├── Utilities/
│   ├── ModelManager.swift       # WhisperKit model download/selection
│   ├── MicrophoneManager.swift  # Microphone device enumeration/selection
│   └── PermissionManager.swift  # Permission checking + settings access
└── Resources/
    └── Assets.xcassets          # App icons, menu bar icon
```

## Design Principles

Muesli follows a Granola-inspired aesthetic: **minimal, clean, fast**.

- **Visual Style**: Clean, monochromatic. Light background, dark text. SF Pro system font.
- **Whitespace**: Generous padding. Let the content breathe.
- **No Clutter**: No unnecessary chrome, borders, gradients, or visual noise.
- **Apple Notes Feel**: Simple, familiar, zero learning curve.

### Color Palette
- Background: System background (adapts to light/dark mode)
- Text: Primary label color
- Accent: System blue (minimal use, only for interactive elements)
- Recording indicator: Subtle red dot

### Typography
- Title: SF Pro, 20pt, semibold
- Transcript: SF Pro, 14pt, regular
- Timestamps: SF Pro, 12pt, secondary label color

## Code Style

### Swift Conventions
- Use Swift 6 concurrency (async/await, actors where appropriate)
- Prefer `@Observable` macro over `ObservableObject` + `@Published`
- Use Swift's native error handling (do/try/catch)
- Keep functions small and focused
- Use meaningful variable names

### SwiftUI Conventions
- Extract reusable components into separate views
- Use `@State` for view-local state, ViewModel for shared state
- Prefer declarative modifiers over imperative code
- Use SF Symbols for icons

### File Organization
- One primary type per file
- Group related functionality in folders
- Keep imports minimal and sorted

## Key Dependencies

### WhisperKit
- Repository: https://github.com/argmaxinc/WhisperKit
- Usage: On-device speech-to-text
- Models: `base` for real-time, `large-v3` for post-recording (future)

### ScreenCaptureKit (System Framework)
- Usage: Capture system audio from meeting apps + microphone
- Requires: Screen Recording permission, Microphone permission

## Architecture Notes

### Audio Pipeline (Parallel Fork Design)
```
ScreenCaptureKit SCStream
         │
    ┌────┴────┐
    ▼         ▼
  System    Microphone
  Audio     Audio (macOS 15+)
    │         │
    ├─────────┼──────────────────┐
    ▼         ▼                  ▼
AVAssetWriter AVAssetWriter   Resample to 16kHz mono
(audio.caf)  (microphone.caf)    │
                                 ├─── System → "Them"
                                 ├─── Mic → "Me"
                                 ▼
                            WhisperKit
                            (transcribe)
                                 │
                                 ▼
                           Live Transcript
                        with Speaker Labels
```

- System audio (48kHz, stereo, Float32) → `audio.caf`
- Microphone audio (24kHz, mono, Float32) → `microphone.caf`
- Separate files because CAF doesn't support multiple audio tracks
- Both streams saved simultaneously via separate AVAssetWriters

### Single Main Window Architecture

The app uses a single main window with dynamic content based on state:

```
┌─────────────────────────────────────────────────────────┐
│                   MuesliViewModel                        │
│  (app state, services, meeting history, active session)  │
└─────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────┐
│                    MainWindowView                        │
│  ┌───────────────────────────────────────────────────┐  │
│  │  UnifiedHistoryView (no recording active)          │  │
│  │  - Meeting list grouped by date                    │  │
│  │  - "+ Start Recording" button                      │  │
│  └───────────────────────────────────────────────────┘  │
│                          OR                              │
│  ┌─────────────┬─────────────────────────────────────┐  │
│  │  Sidebar    │    RecordingDetailView               │  │
│  │  (history)  │    - Live transcript                 │  │
│  │             │    - Floating control bar            │  │
│  │             │    - OR completed meeting            │  │
│  └─────────────┴─────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

**MuesliViewModel** (singleton, app-level):
- Detected meeting apps list
- Permission status
- Services (AudioCapture, FileOutput, Transcription, MeetingHistory)
- Meeting history (all recordings from disk)
- Selected meeting(s) for detail view
- Active recording session tracking
- `isViewingPastMeetingWhileRecording` computed property (for floating indicator)
- `returnToLiveRecording()` method (clears selection to show live recording)

**RecordingSession** (active recording state):
- Session state: `idle` → `recording` → `stopping` → `completed`
- Meeting title, transcript text
- Selected app, output directory
- Timer management

**MeetingHistoryItem** (per-meeting data):
- Title, date, directory path
- Transcript (lazy-loaded)
- Duration (computed from audio file via AVAsset)
- Word count (computed from transcript)
- Audio file presence indicators

### UI Flow
```
Initial State (420px):   Click Meeting:            Recording Active:
┌─────────────────┐     ┌────────┬──────────┐     ┌────────┬──────────┐
│  Meeting List   │ --> │Sidebar │ Meeting  │     │Sidebar │ Live     │
│  + Start Button │     │        │ Transcript│     │        │ Transcript│
│  (unified view) │     │  (split view ~900px)│     │        │ + controls│
└─────────────────┘     └────────┴──────────┘     └────────┴──────────┘
                                                           │
                                                           ▼ (click past meeting)
                                                  ┌────────┬──────────┐
                                                  │Sidebar │ Past     │
                                                  │        │ Meeting  │
                                                  │        │ + [●05:23]│ ← floating indicator
                                                  └────────┴──────────┘
```

**Navigation patterns (Apple Notes-style)**:
- Single-click: Show meeting in detail pane
- Double-click: Open in dedicated window
- Floating indicator: Returns to live recording when clicked

### State Flow
```
User Action → ViewModel → Services → ViewModel (update) → View (re-render)
```

## Permissions

The app requires two permissions:

1. **Screen Recording** (`NSScreenCaptureUsageDescription`)
   - Needed to capture audio from other applications (Zoom, Meet, Teams)
   - User grants via System Settings > Privacy & Security > Screen Recording
   - **Note**: `CGPreflightScreenCaptureAccess()` is unreliable with ad-hoc signing

2. **Microphone** (`NSMicrophoneUsageDescription`)
   - Needed to capture the user's voice
   - Standard microphone permission prompt
   - **Note**: `SCStreamConfiguration.captureMicrophone` requires macOS 15+

Both are requested during the onboarding flow on first launch. On macOS 14, only system audio capture is available via ScreenCaptureKit.

## File Output

Recordings are saved to: `~/Documents/Meeting Transcripts/`

Structure:
```
Meeting Transcripts/
└── 2026-01-04_14-30_Customer-Sync/
    ├── audio.caf        # System audio (48kHz, stereo, Float32 LPCM)
    ├── microphone.caf   # Mic audio (24kHz, mono, Float32 LPCM)
    └── transcript.md
```

If no title is provided, folder uses: `2026-01-04_14-30_Meeting/`

### Why CAF Format?
- CAF (Core Audio Format) is Apple's native uncompressed audio format
- Directly matches SCStream's output (no transcoding overhead)
- Works with QuickLook (spacebar preview) on macOS
- Supports real-time streaming writes

### Transcript Format (Markdown with Speaker Labels)
```markdown
# Customer Sync
2026-01-04 14:30

## Transcript

[00:00] **Them**: Good morning everyone, let's get started.
[00:05] **Me**: Hey, thanks for setting this up.
[00:12] **Them**: Sure thing. So first item on the agenda...
```

**Speaker Labels**:
- `**Me**`: Transcribed from microphone audio (user's voice)
- `**Them**`: Transcribed from system audio (meeting participants)

## Testing Notes

- Test with actual Zoom/Meet/Teams calls when possible
- Use QuickTime Player playing audio as a simpler test case
- Verify permissions flow on a fresh user account
- Test recording start/stop cycle multiple times
- Verify transcript accuracy with clear speech

## Reference Projects

Study these for implementation patterns:

1. **Azayaka** (https://github.com/Mnpn/Azayaka)
   - Menu bar app structure
   - ScreenCaptureKit audio capture
   - macOS app lifecycle

2. **WhisperKit Sample** (https://github.com/rudrankriyam/WhisperKit-Sample)
   - WhisperKit integration
   - Audio recording + transcription flow

3. **Apple's ScreenCaptureKit Sample**
   - Official patterns for SCStream, SCContentFilter
   - CMSampleBuffer handling

## Common Pitfalls

This section documents technical gotchas, constraints, and solutions discovered during development. When adding new entries:

1. **Use descriptive subsection headings** - Group related pitfalls (e.g., "Swift Concurrency", "ScreenCaptureKit")
2. **Format consistently** - Use bullet points with bold keywords, problem description, and solution
3. **Be specific** - Include code examples, API names, or version requirements when relevant
4. **Cross-reference** - Link to related constraints in AGENTS.md "Known technical constraints" when appropriate

### Swift Concurrency
- `CMSampleBuffer` is **not Sendable** and cannot cross actor isolation boundaries
- Solution: Use synchronous callbacks with `NSLock` for buffer handling, not actor isolation
- Mark delegate callbacks as `nonisolated` if needed

### ScreenCaptureKit
- **SCContentFilter**: Must use `SCContentFilter(display:including:exceptingWindows:)` for audio capture
- `SCContentFilter(desktopIndependentWindow:)` does NOT capture audio properly
- Display-based filters require minimal video config (we use 2x2px at 1fps)
- **macOS 15+**: `captureMicrophone` API added. Use `#available(macOS 15.0, *)` checks

### TCC Permissions (Debug Builds)
- `CGPreflightScreenCaptureAccess()` is unreliable with ad-hoc code signing
- TCC database ties permissions to code signature hash, which changes per rebuild
- Solution: Reset TCC permissions on each build via build script

### Audio Format
- CAF format doesn't support multiple audio tracks in a single file
- System audio (48kHz stereo) and mic audio (24kHz mono) must be separate files
- Use Linear PCM (Float32) to match SCStream's native output

### Meeting App Detection
- Do NOT use `SCShareableContent.excludingDesktopWindows()` for app detection—it triggers permission prompts
- Use `NSWorkspace.shared.runningApplications` instead (no permissions required)

### WhisperKit
- **Audio format**: WhisperKit expects 16kHz mono Float32 audio
- **Resampling required**: System audio (48kHz stereo) and mic audio (24kHz mono) must be converted
- **High-quality resampling**: Use `AVAudioConverter` instead of linear interpolation for better audio fidelity
- **Interleaved audio**: CMSampleBuffer from ScreenCaptureKit provides interleaved stereo audio; deinterleave before conversion
- **Model download**: First run downloads the model (~150MB for base). Handle during onboarding.
- **Speaker labeling**: Transcribe system and mic audio separately, label as "Them" and "Me" respectively
- **Model validation**: Always check `config.json` exists in model directory before initializing WhisperKit
- **Progress callback**: `WhisperKit.download(progressCallback:)` requires `@Sendable`; use `Task { @MainActor }` for UI updates
- **Progress granularity**: WhisperKit reports progress in ~5% increments; use a visual progress bar for smoother UX
- **Neural Engine**: WhisperKit automatically uses Neural Engine on Apple Silicon (M-series chips) for optimal performance
- **Transcription modes**: Supports both live (real-time) and post-processing modes for different accuracy/speed tradeoffs
- **Chunk overlap**: Uses 1.5-second overlap between chunks to improve word boundary detection
- **Voice Activity Detection**: Skips silent chunks using RMS energy threshold to reduce false transcriptions

### ModelManager Architecture
- **Single source of truth**: `ModelManager` owns all model state (downloaded models, active model, download progress)
- **ViewModel access**: `MuesliViewModel.modelPath` is a computed property that reads from `modelManager.activeModelPath`
- **DO NOT duplicate state**: Never store model path in both ModelManager and ViewModel
- **Shared instance**: OnboardingView must use `viewModel.modelManager`, not create its own instance
- **Model storage**: Models stored in `~/Library/Application Support/Muesli/Models/`
- **Persistence**: Uses UserDefaults for `downloadedModels` set and `activeModel` selection

### Onboarding Window (SwiftUI)
- **Manual window creation**: SwiftUI `Window` scenes can be unreliable for programmatic opening; use `NSWindow` + `NSHostingController` in `AppDelegate` for guaranteed behavior
- **Closing the correct window**: When `openWindow(id:)` is called, the new window becomes the key window immediately. If you then call `NSApplication.shared.keyWindow?.close()`, you'll close the window you just opened instead of the original window. **Solution**: Capture a reference to the window you want to close BEFORE calling `openWindow`.
- **UserDefaults reset**: Build script clears UserDefaults (`defaults delete com.muesli.app`) to ensure fresh onboarding state on each rebuild
- **Layout strategy**: Use fixed-size content area with fixed-height bottom bar for progress indicator; avoid `Spacer()` in variable-size content areas

### Meeting History & Selection
- **Apple Notes-style navigation**: Single-click shows meeting in detail pane, double-click opens dedicated window
- **Multi-select pattern**: Use a `Set<UUID>` for selected meeting IDs alongside single `selectedMeeting` for detail view
- **Single click vs double-click**: In SwiftUI, use `.onTapGesture(count: 2)` BEFORE `.onTapGesture(count: 1)` - order matters for gesture recognition
- **Shift+click range selection**: Track the last selected item and select all items between it and the clicked item
- **Cmd+click**: Toggle individual selection without clearing others
- **Delete key handling**: Use `.onDeleteCommand { }` modifier on the parent view
- **Hover state**: Use `@State private var isHovered = false` with `.onHover { }` modifier
- **Confirmation dialog**: Use `.alert(isPresented:)` with destructive button role for delete confirmation

### Floating Recording Indicator
- **When to show**: `viewModel.isViewingPastMeetingWhileRecording` (active recording AND selectedMeeting != nil)
- **Return to live**: Call `viewModel.returnToLiveRecording()` which clears `selectedMeeting`
- **Placement**: Bottom-right corner of detail pane using `ZStack(alignment: .bottomTrailing)`
- **Style**: Pill shape with pulsing red dot + waveform icon + elapsed time (e.g., "● 05:23")

### Contextual Window Sizing
- **Unified list view**: Fixed 420px width for compact meeting list
- **Split view**: Min 750px, ideal 900px for sidebar + detail pane
- **Implementation**: Use `.frame()` modifiers with different constraints per view mode
- **Window resizability**: `.windowResizability(.contentSize)` lets SwiftUI manage based on content

### Other
- **CMSampleBuffer timing**: Use presentation timestamps for accurate transcript timing.
- **Menu bar app lifecycle**: LSUIElement apps don't appear in Dock. Ensure there's always a way to quit.

### Adding New Pitfalls

When documenting a new pitfall, follow this format:

```
### Category Name
- **Issue**: Brief description of the problem
- **Why it happens**: Explanation of root cause (if known)
- **Solution**: How to work around or fix it
- **Related**: Cross-reference to AGENTS.md constraint or SPEC.md requirement if applicable
```

**Example**: If you discover that WhisperKit requires a specific audio format:
```
### WhisperKit Audio Format
- **Issue**: WhisperKit expects mono audio at 16kHz, but SCStream provides stereo at 48kHz
- **Why it happens**: WhisperKit models are trained on specific audio characteristics
- **Solution**: Convert audio buffers to mono and resample to 16kHz before feeding to WhisperKit
- **Related**: See AGENTS.md "Known technical constraints" for audio pipeline details
```

## Development Phases

This project is built incrementally. See `SPEC.md` for detailed phase breakdown.

- **Phase 0**: Project setup, XcodeBuildMCP, dependencies
- **Phase 1**: Menu bar shell + main window UI
- **Phase 2**: Audio capture with parallel pipeline architecture
- **Phase 2.5**: Onboarding flow (permissions + model download)
- **Phase 3**: Real-time transcription with "Me" vs "Them" speaker labels
- **Phase 4**: Polish & refinement

Each phase has a checkpoint—verify it works before moving on.
