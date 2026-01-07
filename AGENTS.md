# AGENTS.md — Muesli (macOS local‑first meeting transcription)

This repo builds **Muesli**, a local‑first meeting transcription app for macOS:
- Captures meeting audio (Zoom/Teams/Meet via browser) + mic
- Real‑time on‑device transcription via WhisperKit
- Saves `audio.caf` + `microphone.caf` + `transcript.md` to a local folder

Authoritative docs:
- `SPEC.md` = product spec + phased plan + checkpoints (follow it)
- `CLAUDE.md` = architecture notes, conventions, build commands, pitfalls

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
Run these from the repo root:

**IMPORTANT**: Before building, always kill the running Muesli app first:
```bash
killall Muesli
```
Or quit the app from the menu bar. This prevents build failures from trying to overwrite a running executable.

- Build: `xcodebuild -scheme Muesli -configuration Debug build`
- Test: `xcodebuild -scheme Muesli -configuration Debug test`
- Clean: `xcodebuild -scheme Muesli clean`
- Open in Xcode: `open Muesli.xcodeproj`

If XcodeBuildMCP is configured, prefer using MCP build/test/clean tools.

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

If you are missing information (bundle ID list, Info.plist details, UI sizing, etc.), consult `SPEC.md` first, then `CLAUDE.md`.

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
- New pitfalls found → Add to constraints or create new section
- Response format needs adjustment → "When you respond to the user" section

**CLAUDE.md** - Update when:
- New pitfalls discovered → "Common Pitfalls" section with detailed explanation
- Architecture details change → Relevant architecture diagrams/notes
- Build/test procedures evolve → "Build Commands" or "Testing Notes"
- Dependencies change → "Key Dependencies" section
- Code patterns established → "Code Style" or "Architecture Notes"
- Testing strategies refined → "Testing Notes" section

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
  - CLAUDE.md: Add to "Common Pitfalls" → "ScreenCaptureKit" section with explanation
  - AGENTS.md: Add to "Known technical constraints" → "Display-based SCContentFilter" bullet

**Example 2: Architecture Decision Made**
- **Situation**: Decided to use separate CAF files for system/mic audio instead of mixing
- **Updates**:
  - SPEC.md: Update "Audio Pipeline" section with rationale
  - CLAUDE.md: Update "Audio Pipeline" diagram and add explanation
  - AGENTS.md: Update "Core architecture" → "Audio pipeline" description

**Example 3: Build Procedure Refined**
- **Situation**: Discovered TCC permission reset needed on each build with ad-hoc signing
- **Updates**:
  - CLAUDE.md: Add detailed explanation in "TCC Permissions (Debug Builds)" section
  - AGENTS.md: Update "Note on Permissions" section with build script approach

**Example 4: Phase Checkpoint Adjusted**
- **Situation**: Phase 2 checkpoint needs to verify both audio files play correctly
- **Updates**:
  - SPEC.md: Update Phase 2 checkpoint with specific verification steps
  - CLAUDE.md: Add testing note about verifying CAF playback

## When you respond to the user
When you make changes:
- Summarize what you changed and why
- List files touched (including documentation if updated)
- Provide build/test commands you ran (or should be run)
- Call out any follow‑ups needed to meet the phase checkpoint
