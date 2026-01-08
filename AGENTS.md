# AGENTS.md — Muesli (macOS local‑first meeting transcription)

This repo builds **Muesli**, a local‑first meeting transcription app for macOS:
- Captures meeting audio (Zoom/Teams/Meet via browser) + mic
- Real‑time on‑device transcription via WhisperKit
- Saves `audio.caf` + `microphone.caf` + `transcript.md` to a local folder

Authoritative docs:
- `SPEC.md` = product spec + phased plan + checkpoints (follow it)
- This file (AGENTS.md) = architecture notes, conventions, build commands, pitfalls

## Quick reference
- Platform: macOS 14+ (Sonoma)
- Language: Swift 6
- UI: SwiftUI
- Architecture: `MuesliViewModel` (app state) + `RecordingSession` (per-window state)
- Audio capture: ScreenCaptureKit
- Transcription: WhisperKit
- Package manager: Swift Package Manager

## How to work in this repo (agent rules)
1. **Follow the phase plan in `SPEC.md`**. Do *not* jump ahead. Implement one phase at a time and verify the checkpoint before continuing.
2. **Small diffs, compile often.** Prefer minimal, incremental changes over large refactors.
3. **Always keep the app buildable.** If you break the build, fix it before doing anything else.
4. **Prefer native patterns**:
   - Swift 6 concurrency (`async/await`) and clear threading boundaries
   - `@Observable` (avoid unnecessary `ObservableObject/@Published`)
   - Small, focused types; one primary type per file
5. **UI principle:** “Granola‑inspired”: minimal, clean, fast. Avoid visual clutter.

## Commands

**Kill, Build, and Launch** (single command):
```bash
killall Muesli 2>/dev/null; xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug build -quiet && open ~/Library/Developer/Xcode/DerivedData/Muesli-*/Build/Products/Debug/Muesli.app
```

Individual commands:
- Kill app: `killall Muesli`
- Build (fast): `xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug build -quiet`
- Launch: `open ~/Library/Developer/Xcode/DerivedData/Muesli-*/Build/Products/Debug/Muesli.app`
- Test: `xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug test`
- Clean: `xcodebuild -project Muesli.xcodeproj -scheme Muesli clean`
- Open in Xcode: `open Muesli.xcodeproj`

**Critical**: Always use `-quiet` flag. Without it, builds log every compile step and take 5+ minutes instead of ~15 seconds.

**Note on Permissions & App State**: With ad-hoc (debug) signing, TCC permissions and UserDefaults are reset automatically on each build via a build script. This ensures a clean permission and onboarding state since `CGPreflightScreenCaptureAccess()` is unreliable with ad-hoc signing. The native macOS permission dialogs will appear when needed, and the onboarding flow will run on each fresh build.

To manually reset permissions:
```bash
tccutil reset ScreenCapture com.muesli.app
tccutil reset Microphone com.muesli.app
```

## Project structure (expected)

Muesli/
- MuesliApp.swift
- Models/
  - MeetingApp.swift
  - MeetingHistoryItem.swift
  - RecordingSession.swift
- ViewModels/
  - MuesliViewModel.swift
- Views/
  - MainWindowView.swift (switches between unified/split view)
  - UnifiedHistoryView.swift (meeting list when idle)
  - MeetingHistorySidebar.swift (sidebar during/after recording)
  - RecordingDetailView.swift (live transcript or completed meeting)
  - StartRecordingSheet.swift (app picker)
  - CompletedMeetingWindow.swift (dedicated window for past meetings)
  - MenuBarView.swift
  - OnboardingView.swift
  - Components/
- Services/
  - AudioCaptureService.swift
  - MeetingAppDetector.swift
  - MeetingHistoryService.swift
  - TranscriptionService.swift
  - FileOutputService.swift
- Utilities/
  - ModelManager.swift
  - MicrophoneManager.swift
  - PermissionManager.swift
- Resources/

Keep imports minimal and sorted. Put reusable UI in `Views/Components`.

## Core architecture (high‑level)
- `MuesliApp` hosts MenuBarExtra + single main Window
- **Single-window model**: Main window shows either:
  - `UnifiedHistoryView` (meeting list) when idle (no recording, no meeting selected)
  - Split view (`MeetingHistorySidebar` + `RecordingDetailView`) when viewing a meeting or recording
- **Contextual sizing**: Window is 420px wide for unified list, expands to 750-900px for split view
- `MuesliViewModel` owns shared app state and services:
  - `AudioCaptureService` (ScreenCaptureKit)
  - `TranscriptionService` (WhisperKit)
  - `FileOutputService` (save audio + transcript)
  - `MeetingHistoryService` (discover/load past meetings)
  - `ModelManager` (WhisperKit model download/selection)
  - `MicrophoneManager` (device enumeration/selection)
  - Meeting history, selected meetings, active session tracking
- `RecordingSession` owns active recording state:
  - Session state (idle → recording → completed)
  - Meeting title, transcript, output directory
  - Timer management
- `MeetingHistoryItem` represents a past meeting:
  - Title, date, directory, transcript (lazy-loaded)
  - Duration (from audio file) and word count (from transcript)
  - Audio file presence indicators
- `ModelManager` owns model state:
  - Downloaded models set, active model selection
  - Model download with progress tracking
  - Persists to UserDefaults, stores models in ~/Library/Application Support/Muesli/Models
- Audio pipeline uses a parallel fork:
  - save audio to disk (AVAssetWriter)
  - convert to PCM → transcribe (WhisperKit)

## UI interaction patterns
- **Meeting list (Apple Notes-style navigation)**:
  - Single-click: Immediately shows meeting transcript in detail pane
  - Double-click: Opens meeting in dedicated window
  - Cmd+click: Toggle multi-select for bulk operations
  - Shift+click: Range selection
- **Floating recording indicator**: When viewing a past meeting during active recording, a pill-shaped indicator (red dot + waveform + elapsed time) appears in bottom-right. Clicking it returns to live recording.
- **Floating control bar**: During recording, shows mic picker, transcription mode, stop button
- **Deletion**: Hover X icon, right-click menu, or Delete key with confirmation
- **History grouping**: By day for last week, by month for older meetings
- **Meeting metadata**: Duration and word count displayed on list rows (e.g., "47 min · 1,240 words")
- **Contextual window sizing**: Narrower (420px) for unified list, wider (750-900px) for split view with detail pane
- **Onboarding flow**: Always show welcome screen first; do NOT auto-advance to permission screens. Auto-advance only when ALL permissions are already granted (to skip directly to model setup or complete onboarding).

## Permissions (must be handled)
The app requires:
- Screen Recording permission (for capturing app audio)
- Microphone permission (for mic audio)

Ensure Info.plist contains the correct usage description keys as specified in `SPEC.md`.

## Output contract
Recordings are saved under:
`~/Documents/Meeting Transcripts/YYYY-MM-DD_HH-MM_[Title]/`
containing:
- `audio.caf` (system audio: 48kHz, stereo, Float32 LPCM)
- `microphone.caf` (mic audio: 24kHz, mono, Float32 LPCM)
- `transcript.md` (Markdown with timestamps)

Do not change this contract without updating `SPEC.md` and explaining why.

## Known technical constraints
- **CAF format**: Used because it matches SCStream's native output and supports real-time writes
- **Separate audio files**: CAF doesn't support multiple tracks; system + mic have different sample rates
- **Display-based SCContentFilter**: Required for audio capture; window-based filters don't work
- **CMSampleBuffer**: Not Sendable; use synchronous callbacks with `OSAllocatedUnfairLock`, not actor isolation
- **Microphone capture**: `SCStreamConfiguration.captureMicrophone` requires macOS 15+
- **WhisperKit audio**: Requires 16kHz mono Float32; system (48kHz stereo) and mic (24kHz mono) must be resampled
- **High-quality resampling**: Use `AVAudioConverter` for resampling instead of linear interpolation to maintain audio fidelity
- **Interleaved audio handling**: CMSampleBuffer provides interleaved stereo; must deinterleave before AVAudioConverter processing
- **Speaker labeling**: System audio → "Them", mic audio → "Me" (separate transcription streams)
- **Transcription modes**: Live (real-time) and post-processing (after recording) modes available; post-processing allows larger models for better accuracy
- **Chunk overlap**: 1.5-second overlap between chunks improves word boundary detection
- **Voice Activity Detection**: RMS energy threshold (-40dB equivalent) skips silent chunks to reduce false transcriptions
- **Neural Engine optimization**: WhisperKit automatically uses Neural Engine on Apple Silicon; no explicit configuration needed
- **Model management**: `ModelManager` is the single source of truth for model paths; ViewModel retrieves path via computed property
- **Model validation**: Always check `config.json` exists before initializing WhisperKit; fail fast with clear error messages
- **WhisperKit download progress**: Progress callback requires `@Sendable` and `Task { @MainActor }` dispatch for UI updates
- **Window opening order**: `openWindow(id:)` makes the new window the key window immediately; capture window references BEFORE opening new windows if you need to close the original
- **Multi-select with gestures**: Place `.onTapGesture(count: 2)` before `.onTapGesture(count: 1)` in SwiftUI; order matters for recognition

## Checkpoint discipline (important)
At the end of each phase:
- Run the build (and tests if present)
- Confirm the checkpoint criteria in `SPEC.md`
- Only then proceed to the next phase

If you are missing information (bundle ID list, Info.plist details, UI sizing, etc.), consult `SPEC.md` first.

## Documentation Updates

After completing debugging, stabbing, or finishing a phase, evaluate whether core documentation needs updates based on lessons learned.

### When to Update Documentation

Consider updates after:
- **Completing a phase checkpoint** - Capture what was actually implemented vs. planned
- **Resolving a bug** - Document root cause and solution if it's a recurring pattern
- **Debugging a complex issue** - Add pitfalls, constraints, or workarounds discovered
- **Adding a new component** - Update architecture diagrams, project structure, or patterns
- **Discovering a technical constraint** - Document limitations that affect future work

### What to Update Where

**AGENTS.md** - Update when:
- Technical constraints discovered → "Known technical constraints" section
- Build/test commands change → "Commands" section
- Project structure evolves → "Project structure (expected)" section
- Architecture patterns change → "Core architecture (high-level)" section
- New pitfalls found → "Common Pitfalls" section with detailed explanation
- Architecture details change → Relevant architecture diagrams/notes
- Dependencies change → "Key Dependencies" section
- Code patterns established → "Code Style" section
- Testing strategies refined → "Testing Notes" section
- Response format needs adjustment → "When you respond to the user" section

**SPEC.md** - Update when:
- Phase requirements change → Update task lists in phase sections
- Checkpoints need adjustment → Modify checkpoint criteria based on what's testable
- Architecture decisions impact spec → "Technical Architecture" section
- UI specs need refinement → "UI Specifications" based on implementation reality
- Output format changes → File output specifications

**`.cursorrules`** - Update when:
- New agent workflow patterns → Add rules that prevent future mistakes
- Common mistakes discovered → Add explicit rules to prevent them
- Response format needs standardization → "OUTPUT REQUIREMENTS"
- Phase discipline needs reinforcement → "PHASE DISCIPLINE" section

### Update Process

1. **Reflect**: What did I learn? What was different from expectations? What would help future work?
2. **Categorize**: Technical constraint, architecture decision, build/test procedure, code pattern, phase adjustment, or agent workflow
3. **Update**: Locate appropriate section, add concise actionable content, maintain consistency, cross-reference when helpful
4. **Verify**: All significant learnings captured, consistency maintained, formatting matches style

### Guidelines

- **Be selective**: Focus on recurring patterns, architectural decisions, constraints affecting future work, procedures differing from expectations
- **Be concise**: Use bullet points, code examples, clear headings
- **Be actionable**: Focus on what future work needs to know
- **Maintain consistency**: Follow existing documentation style and structure
- **Cross-reference**: Ensure consistency when information appears in multiple files

### Examples

**Example 1: New Pitfall Discovered**
- **Situation**: Discovered that `SCContentFilter` must use display-based filter for audio capture
- **Updates**:
  - AGENTS.md: Add to "Common Pitfalls" → "ScreenCaptureKit" section with explanation
  - AGENTS.md: Add to "Known technical constraints" → "Display-based SCContentFilter" bullet

**Example 2: Architecture Decision Made**
- **Situation**: Decided to use separate CAF files for system/mic audio instead of mixing
- **Updates**:
  - SPEC.md: Update "Audio Pipeline" section with rationale
  - AGENTS.md: Update "Core architecture" → "Audio pipeline" description
  - AGENTS.md: Update architecture diagrams if needed

**Example 3: Build Procedure Refined**
- **Situation**: Discovered TCC permission reset needed on each build with ad-hoc signing
- **Updates**:
  - AGENTS.md: Add detailed explanation in "TCC Permissions (Debug Builds)" section
  - AGENTS.md: Update "Note on Permissions" section with build script approach

**Example 4: Phase Checkpoint Adjusted**
- **Situation**: Phase 2 checkpoint needs to verify both audio files play correctly
- **Updates**:
  - SPEC.md: Update Phase 2 checkpoint with specific verification steps
  - AGENTS.md: Add testing note about verifying CAF playback

## When you respond to the user
When you make changes:
- Summarize what you changed and why
- List files touched (including documentation if updated)
- Provide build/test commands you ran (or should be run)
- Call out any follow‑ups needed to meet the phase checkpoint

## Common Pitfalls

This section documents technical gotchas, constraints, and solutions discovered during development.

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
- **Welcome screen auto-advance**: Do NOT auto-advance from the welcome screen to permission screens. Users should always see "Welcome to Muesli" first and click "Get Started" to proceed.

### Meeting History & Selection
- **Apple Notes-style navigation**: Single-click shows meeting in detail pane, double-click opens dedicated window
- **Multi-select pattern**: Use a `Set<UUID>` for selected meeting IDs alongside single `selectedMeeting` for detail view
- **Single click vs double-click**: In SwiftUI, use `.onTapGesture(count: 2)` BEFORE `.onTapGesture(count: 1)` - order matters for gesture recognition

### Other
- **CMSampleBuffer timing**: Use presentation timestamps for accurate transcript timing.
- **Menu bar app lifecycle**: LSUIElement apps don't appear in Dock. Ensure there's always a way to quit.

## Key Dependencies

### WhisperKit
- Repository: https://github.com/argmaxinc/WhisperKit
- Usage: On-device speech-to-text
- Models: `base` for real-time, `large-v3` for post-recording (future)

### ScreenCaptureKit (System Framework)
- Usage: Capture system audio from meeting apps + microphone
- Requires: Screen Recording permission, Microphone permission

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
