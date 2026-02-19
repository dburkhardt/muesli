# Muesli - Software Design Specification

**Note for agents**: Additional flow-specific documentation lives in the `spec/` folder. If you are doing a comprehensive architecture review, read those documents as well.

## Overview

**Muesli** is a local-first meeting transcription app for macOS. It captures system audio plus microphone input, transcribes in real-time using on-device AI (WhisperKit), and saves audio plus transcript for later review and refinement.

Think of it as a local, privacy-focused alternative to Granola—without cloud dependencies for transcription.

## Goals

1. **Capture meeting audio** from Zoom, Teams, or Google Meet without joining as a bot
2. **Real-time transcription** displayed during the meeting so you can glance at what was said
3. **Local processing** using WhisperKit on Apple Silicon (M3 MacBook Air target)
4. **Save recordings** as audio file + markdown transcript for upload to LLMs later
5. **Minimal, beautiful UI** inspired by Granola's clean aesthetic

## Non-Goals (for MVP)

- Auto-detection of meeting start/end (manual start via menu bar)
- In-app note-taking (user can use Notes.app separately)
- Speaker diarization (future enhancement)
- LLM-powered summarization (done externally via Gemini/Claude)
- Calendar integration
- Cloud sync

---

## User Experience

### First Launch

1. App opens an onboarding window explaining what Muesli does
2. User is guided through granting System Audio Recording permission
3. User is guided through granting Microphone permission
4. User downloads or selects an existing WhisperKit transcription model
5. Once setup is complete, onboarding finishes
6. App opens the main window (menu bar remains available at all times)

### Starting a Recording

1. User clicks menu bar icon → "Start Recording" (or clicks "New" in the main window)
2. Muesli starts a recording session in the main window split view
3. User can optionally enter/edit the meeting title during recording
4. Live transcript appears as audio is processed
5. Menu bar shows recording status with "Stop Recording" option

### During Recording

1. Main window displays transcript updating in real-time
2. User can optionally enter a meeting title in the text field at top
3. User can minimize/hide the window and continue recording
4. Menu bar dropdown shows "Stop Recording" option

### Stopping a Recording

1. User clicks "Stop Recording" in the menu bar or main window
2. Recording is saved to `~/Library/Application Support/Muesli/Recordings/YYYY-MM-DD_HH-MM_[UUID]/`
   - Folder name uses timestamp + UUID for uniqueness (e.g., `2026-01-15_14-30_A1B2C3D4-E5F6-7890-ABCD-EF1234567890`)
   - Meeting title is stored in `transcript.md` header, not in folder name
   - This ensures stable folder names even when titles change, supporting future history features
   - Using Application Support instead of Documents avoids permission prompts and follows macOS best practices
3. Folder contains `audio.caf`, `microphone.caf`, and `transcript.md`
   - Resumed recordings may include additional segment files such as `audio_2.caf` and `microphone_2.caf`
4. Meeting history refreshes and the completed meeting remains selectable in the split view

### Ongoing Use

- App runs at login (menu bar icon always available)
- User can access Preferences to change settings
- User can quit from menu bar dropdown

---

## Technical Architecture

### App Structure

```
┌─────────────────────────────────────────────────────────┐
│                      MuesliApp                          │
│  ┌─────────────────┐  ┌─────────────────────────────┐  │
│  │  MenuBarExtra   │  │      Main Window            │  │
│  │  (quick access) │  │  (`Window` id: "main")      │  │
│  └─────────────────┘  └─────────────────────────────┘  │
│                              │                          │
│                      ┌───────▼────────┐                 │
│                      │ MuesliViewModel │                 │
│                      │  (coordinator)  │                 │
│                      └───────┬────────┘                 │
│                              │                          │
│      ┌───────────────────────┼──────────────────────┐   │
│      ▼                       ▼                      ▼   │
│  RecordingController   MeetingHistoryManager   RefinementCoordinator
│      │                                                 │
│      ▼                                                 ▼
│  TapAudioCaptureService  TranscriptionCoordinator  ExportService
└─────────────────────────────────────────────────────────┘
```

**Window Architecture**: The app uses a single main `Window` (`id: "main"`) for recording/history workflows, plus on-demand windows (`modelManagement`, `completedMeeting`, `about`) and a dedicated onboarding `NSWindow` managed by `AppDelegate`.

### State Architecture

**Delegation Pattern** (implemented):

MuesliViewModel acts as a coordinator that delegates state management to focused managers:

```
MuesliViewModel (Coordinator)
│
├── RecordingController (owns recording lifecycle)
│   ├─ activeSession: RecordingSession?
│   ├─ Audio/Transcription/FileOutput Services
│   ├─ Real-time audio callbacks (nonisolated(unsafe))
│   └─ Recording lifecycle state machine
│
├── PreferencesManager (owns preferences state)
│   ├─ outputDirectory: URL
│   ├─ launchAtLogin: Bool
│   ├─ transcriptionMode: TranscriptionMode
│   └─ isEchoCancellationEnabled: Bool
│
├── MeetingHistoryManager (owns meeting history state)
│   ├─ meetingHistory: [MeetingHistoryItem]
│   ├─ groupedHistory: [MeetingHistoryGroup]
│   ├─ selectedMeeting: MeetingHistoryItem?
│   ├─ selectedMeetingIDs: Set<UUID>
│   └─ meetingsPendingDeletion: [MeetingHistoryItem]
│
└── RefinementCoordinator (owns refinement state)
    ├─ showRefineSheet: Bool
    ├─ meetingBeingRefined: MeetingHistoryItem?
    ├─ canRefineTranscripts: Bool
    └─ showOriginalTranscript tracking per meeting
```

**ViewModel delegation pattern:**
```swift
// Computed properties delegate to managers
var outputDirectory: URL {
    get { preferencesManager.outputDirectory }
    set { preferencesManager.outputDirectory = newValue }
}

var meetingHistory: [MeetingHistoryItem] {
    get { historyManager.meetingHistory }
    set { historyManager.meetingHistory = newValue }
}
```

**Benefits:**
- Clear separation of concerns (each manager has focused responsibility)
- Testable components (managers tested in isolation)
- Single source of truth for views (only observe ViewModel)
- Stable API (delegation transparent to views)
- Recording logic preserved (~600 lines of tightly-coupled audio pipeline)

**RecordingSession** (per-recording state):
```swift
@Observable
class RecordingSession: Identifiable {
    let id: UUID
    
    enum SessionState { case idle, recording, stopping, completed }
    var state: SessionState = .idle
    
    var meetingTitle: String = ""
    var transcriptText: String = ""
    var recordingStartTime: Date?
    var outputDirectory: URL?
    var selectedApp: MeetingApp?
}
```

### Audio Pipeline

The audio pipeline uses parallel capture with separate files for system and microphone audio:

```
┌──────────────────────┐    ┌──────────────────────┐
│  Core Audio Tap      │    │  AVAudioEngine       │
│  (Output Mix)        │    │  (Microphone)        │
│                      │    │                      │
│  System audio        │    │  User's microphone   │
│  (Muesli excluded)   │    │  (device selectable) │
└──────────┬───────────┘    └──────────┬───────────┘
           │                           │
           │ 48kHz stereo              │ 48kHz mono
           └───────────┬───────────────┘
                       │
                       ▼
    ┌───────────────────────────────┐
    │ TapAudioCaptureService        │
    │ (synchronizer + AEC worker)   │
    └──────────────┬────────────────┘
                   │
                   ▼
          ┌───────────────────────────┐
          │     RecordingController   │
          └───────────┬───────────────┘
                       │
           ┌───────────┴───────────┐
           │                       │
           ▼                       ▼
    ┌──────────────┐     ┌─────────────────────┐
    │FileOutput    │     │TranscriptionService │
    │Service       │     │                     │
    │              │     │ Resample: 48kHz     │
    │audio.caf    │     │  → 16kHz mono       │
    │microphone   │     │                     │
    │  .caf       │     │ WhisperKit          │
    └──────────────┘     │ transcription       │
                         └─────────────────────┘
```

**Note**: System audio and microphone audio are saved to separate CAF files because:
- CAF format doesn't support multiple audio tracks
- Separate files allow independent post-processing
- Users can reprocess with different speaker assignments

**Note**: Microphone capture uses AVAudioEngine (not tap capture APIs) so users can choose their input device and switch devices during recording.

### Meeting App Detection

Use `NSWorkspace` to detect running applications and surface known meeting apps:

```swift
let meetingAppBundleIDs = [
    "us.zoom.xos",           // Zoom
    "com.microsoft.teams",   // Microsoft Teams
    "com.google.Chrome",     // Google Meet (runs in Chrome)
    "com.apple.Safari",      // Google Meet (Safari)
    "com.microsoft.edgemac"  // Teams/Meet in Edge
]
```

For browser-based meetings (Google Meet), we detect the browser app as meeting context. Capture itself is tap-based (system output), so app detection is metadata/UI guidance rather than a hard capture filter.

---

## UI Specifications

### Menu Bar

**Icon**: Template menu bar icon, rendered at 16x16 points

**Dropdown (idle state)**:
```
┌─────────────────────────┐
│ Start Recording         │
├─────────────────────────┤
│ Open Muesli             │
├─────────────────────────┤
│ Preferences...          │
│ Debug Info...           │
│ Check for Updates...    │
├─────────────────────────┤
│ Quit Muesli             │
└─────────────────────────┘
```

**Dropdown (recording state)**:
```
┌─────────────────────────┐
│ ● Recording (02:34)     │
│ Capturing: All System   │
│ Stop Recording          │
├─────────────────────────┤
│ Show Recording Window   │
├─────────────────────────┤
│ Quit Muesli             │
└─────────────────────────┘
```

### Main Window

**Size**: Contextual based on view mode:
- **Unified list view** (no recording, no meeting selected): 420pt wide × 600pt tall
- **Split view** (recording active or meeting selected): 900pt wide × 650pt tall

**Layout**:
```
┌─────────────────────────────────────────────────┐
│  Meeting Title                            ● REC │  <- Title field + recording indicator
├─────────────────────────────────────────────────┤
│                                                 │
│  [00:00] First line of transcript appears here  │
│                                                 │
│  [00:05] As people speak, new lines appear      │
│          below with timestamps...               │
│                                                 │
│  [00:12] The transcript scrolls automatically   │
│          to show the latest content             │
│                                                 │
│                                                 │
│                                                 │
│                                                 │
│                                                 │
│                                                 │
│                                                 │
├─────────────────────────────────────────────────┤
│        [ Stop Recording ]                       │  <- Only shown when recording
└─────────────────────────────────────────────────┘
```

**Visual Style**:
- Background: `.background` (system background color)
- Title field: Borderless, placeholder "Meeting Title", SF Pro 20pt semibold
- Transcript: SF Pro 14pt regular, primary label color
- Timestamps: SF Pro 12pt, secondary label color, inline with text
- Recording indicator: Small red circle (8pt), subtle pulse animation
- Stop button: Rounded rect, system red background, white text

### Onboarding Window

**Size**: 520pt wide × ~580-600pt tall (fixed content window)

**Flow** (4 screens):

**Screen 1 - Welcome**:
```
┌─────────────────────────────────────────────────┐
│                                                 │
│                    🎙️                          │
│                                                 │
│              Welcome to Muesli                  │
│                                                 │
│     Local meeting transcription for macOS.      │
│     Your audio never leaves your device.        │
│                                                 │
│                                                 │
│              [ Get Started ]                    │
│                                                 │
└─────────────────────────────────────────────────┘
```

**Screen 2 - Screen Recording Permission**:
```
┌─────────────────────────────────────────────────┐
│                                                 │
│                    🖥️                          │
│                                                 │
│          Screen Recording Access                │
│                                                 │
│   Muesli needs Screen Recording permission      │
│   to capture audio from meeting apps like       │
│   Zoom, Teams, and Google Meet.                 │
│                                                 │
│         [ Open System Settings ]                │
│                                                 │
│   ✓ Permission granted (or: Waiting...)        │
│                                                 │
│              [ Continue ]                       │
└─────────────────────────────────────────────────┘
```

**Screen 3 - Microphone Permission**:
```
┌─────────────────────────────────────────────────┐
│                                                 │
│                    🎤                           │
│                                                 │
│            Microphone Access                    │
│                                                 │
│   Muesli needs Microphone permission to         │
│   capture your voice during meetings.           │
│                                                 │
│         [ Grant Microphone Access ]             │
│                                                 │
│   ✓ Permission granted (or: Waiting...)        │
│                                                 │
│              [ Continue ]                       │
└─────────────────────────────────────────────────┘
```

**Screen 4 - Model Setup**:
```
┌─────────────────────────────────────────────────┐
│                                                 │
│                    🧠                           │
│                                                 │
│           Transcription Model                   │
│                                                 │
│   Muesli uses WhisperKit for on-device          │
│   transcription. Choose your model:             │
│                                                 │
│   Model: [ base ▼ ]                             │
│                                                 │
│   [ Download Model (~150MB) ]                   │
│                                                 │
│   ━━━━━━━━━━░░░░░░░░░░░░░  45%                 │
│                                                 │
│   — or —                                        │
│                                                 │
│   [ Use Existing Model... ]                     │
│                                                 │
│              [ Finish Setup ]                   │
└─────────────────────────────────────────────────┘
```

---

## Storage Architecture

All Muesli data is stored in `~/Library/Application Support/Muesli/` to avoid permission prompts and follow macOS best practices for app data storage.

### Directory Structure

```
~/Library/Application Support/Muesli/
├── Recordings/                    # Meeting recordings and transcripts
│   ├── 2026-01-15_14-30_[UUID]/
│   │   ├── audio.caf              # System audio (meeting participants)
│   │   ├── microphone.caf         # Microphone audio (user's voice)
│   │   ├── transcript.md          # Markdown transcript with speaker labels
│   │   └── transcript.original.md # Original transcript (if refined)
│   └── ...
├── Exports/                       # Exported data for external tools
│   ├── manifest.json              # Global index of all meetings
│   ├── .muesli-export             # Version marker file
│   ├── meetings/
│   │   ├── 2026-01-15_14-30_[UUID]/
│   │   │   ├── transcript.md      # Copy of transcript for external access
│   │   │   └── metadata.json      # Structured metadata (JSON)
│   │   └── ...
│   └── ...
└── Models/                        # WhisperKit transcription models
    └── models/argmaxinc/whisperkit-coreml/
        ├── openai_whisper-base/
        ├── openai_whisper-small/
        └── ...
```

### Export Architecture (External Tool Integration)

Muesli automatically exports meeting transcripts and metadata to a structured folder that external tools (MCP servers, IDE extensions, etc.) can access as a read-only knowledge source.

**Export Location**: `~/Library/Application Support/Muesli/Exports/` (configurable in preferences)

**Automatic Export**: When enabled (default), meetings are exported automatically after recording completes and when transcripts are reprocessed or refined.

**Manual Export**: Users can manually trigger export of all meetings via the "Export All Now" button in Preferences → Output.

#### Export Folder Structure

Each meeting is exported to `Exports/meetings/[FOLDER_NAME]/` with:
- `transcript.md` - Human-readable transcript (Markdown format)
- `metadata.json` - Machine-readable metadata (JSON format)

The export directory also contains:
- `manifest.json` - Global index listing all exported meetings with summary metadata
- `.muesli-export` - Version marker file indicating export format version

#### metadata.json Schema

```json
{
  "id": "UUID",
  "title": "Meeting Title",
  "date": "2026-01-15T14:30:00Z",
  "duration": 2847,
  "wordCount": 1240,
  "hasAudio": true,
  "hasMicrophone": true,
  "isRefined": false,
  "segmentCount": 1,
  "segments": [
    {
      "segmentNumber": 1,
      "startTime": "2026-01-15T14:30:00Z",
      "isRefined": false
    }
  ],
  "files": {
    "transcript": "transcript.md",
    "audio": "../../Recordings/2026-01-15_14-30_[UUID]/audio.caf",
    "microphone": "../../Recordings/2026-01-15_14-30_[UUID]/microphone.caf"
  }
}
```

#### manifest.json Schema

```json
{
  "version": "1.0",
  "generatedAt": "2026-01-18T10:30:00Z",
  "totalMeetings": 42,
  "meetings": [
    {
      "id": "UUID",
      "title": "Meeting Title",
      "date": "2026-01-15T14:30:00Z",
      "directory": "meetings/2026-01-15_14-30_[UUID]",
      "hasAudio": true,
      "hasMicrophone": true,
      "duration": 2847,
      "wordCount": 1240,
      "isRefined": false,
      "segmentCount": 1
    }
  ]
}
```

#### Use Cases for External Tools

External tools can use the export folder to:
- **Search**: Index transcripts for full-text search across all meetings
- **Analysis**: Extract insights, topics, action items from meeting content
- **Integration**: Connect meeting notes with other productivity tools (task managers, note-taking apps, etc.)
- **Backup**: Sync exported data to cloud storage or version control
- **MCP Servers**: Provide meeting context to AI assistants via Model Context Protocol

**Read-Only Access**: External tools should treat the export folder as read-only. Muesli owns the export process and will overwrite files during re-export.

**Version Compatibility**: The `.muesli-export` marker file contains `version=1.0` and `format=markdown+json` to help external tools verify compatibility.

### Recordings Directory
│   │   ├── microphone.caf         # Microphone audio (user's voice)
│   │   ├── transcript.md          # Markdown transcript with speaker labels
│   │   └── transcript.original.md # Original transcript (if refined)
│   └── ...
└── Models/                        # WhisperKit transcription models
    └── models/argmaxinc/whisperkit-coreml/
        ├── openai_whisper-base/
        ├── openai_whisper-small/
        └── ...
```

### LLM Models

LLM models (for transcript refinement) use the standard Hugging Face Hub cache:
- Location: `~/.cache/huggingface/hub/`
- This follows the convention used by other ML applications

### User Preferences

User preferences are stored in standard UserDefaults:
- Output directory (customizable)
- Active transcription model
- Launch at login setting
- Transcription mode (live vs post-processing)
- Echo cancellation setting

### Diagnostic Logs

Diagnostic logs are stored for debugging release build issues:
- Location: `~/Library/Application Support/Muesli/Logs/`
- File naming: `muesli-YYYY-MM-DD.log` (one per day)
- Retention: 7 days (auto-cleanup on launch)
- See [spec/diagnostic_logging.md](spec/diagnostic_logging.md) for full specification

### Why Application Support?

1. **No permission prompts** - Application Support doesn't require user authorization
2. **Appropriate for app data** - Documents is for user-created files, not app-generated data
3. **Standard macOS convention** - Follows Apple's Human Interface Guidelines
4. **Clean separation** - App data stays organized and doesn't clutter user folders

---

## Diagnostic Logging (Required)

Muesli includes a **required** diagnostic logging system that ships with all builds (Debug and Release). This infrastructure is essential for debugging issues that only appear in production builds.

### Purpose

Some bugs only manifest in release builds due to:
- Code signing and notarization differences
- Optimizations affecting dynamic color resolution
- Info.plist embedding differences
- TCC (Transparency, Consent, and Control) behavior with different bundle IDs

The 30+ minute DMG build cycle makes iteration slow. Diagnostic logs persist across reinstalls and can be easily shared for bug reports.

### Components

| Component | Location | Purpose |
|-----------|----------|---------|
| DiagnosticLogger | `Muesli/Utilities/DiagnosticLogger.swift` | Thread-safe actor for file-based logging |
| DebugInfoView | `Muesli/Views/DebugInfoView.swift` | UI panel showing permission states, build info |
| Menu Item | Menu Bar → "Debug Info..." | Access point (available in idle AND onboarding) |

### Log Categories

| Category | What Gets Logged |
|----------|------------------|
| `BUILD` | Bundle ID, version, Info.plist keys (on app launch) |
| `PERMISSION` | Permission checks with raw status values, request outcomes |
| `ONBOARDING` | Step transitions, button tap events |
| `APP` | General app lifecycle events |

### Privacy Policy

Logs contain **only** build/permission metadata. **Never** log:
- Transcript content
- Meeting titles or file names
- User file paths outside Application Support
- Any personally identifiable information

### Accessing Logs

```bash
# View today's log
cat ~/Library/Application\ Support/Muesli/Logs/muesli-$(date +%Y-%m-%d).log

# Search for permission issues
grep PERMISSION ~/Library/Application\ Support/Muesli/Logs/*.log

# Watch in real-time
tail -f ~/Library/Application\ Support/Muesli/Logs/muesli-$(date +%Y-%m-%d).log
```

Or use: Menu Bar → "Debug Info..." → "Open in Finder"

### Full Specification

See [spec/diagnostic_logging.md](spec/diagnostic_logging.md) for complete details including:
- Log format and file management
- Integration points (PermissionManager, OnboardingView)
- Expected log output examples
- Testing procedures

---

## Current Status

The MVP is complete. All core features are implemented and functional.

### Implemented Features

| Feature | Status | Notes |
|---------|--------|-------|
| Menu bar app | ✅ | Runs as LSUIElement (no dock icon) |
| Audio capture | ✅ | System audio via Core Audio taps, mic via AVAudioEngine |
| Real-time transcription | ✅ | WhisperKit with "Me" vs "Them" speaker labels |
| File output | ✅ | CAF audio + Markdown transcript |
| Onboarding | ✅ | Permission flow + model download |
| Meeting history | ✅ | Browse and manage past recordings |
| Transcript reprocessing | ✅ | Re-transcribe with different models |
| Audio-only recording | ✅ | Record when no model available |
| LLM refinement | ✅ | Polish transcripts with local LLM |
| Diagnostic logging | ✅ | File-based logs for debugging release builds |

### Model Support

- **Transcription**: WhisperKit models (tiny, base, small, medium, large-v3, large-v3-turbo)
- **Refinement**: MLX LLM models (Llama 3.2 variants)

### Deep Dive Documentation

For detailed behavior specifications, see the `spec/` folder:

| Document | Topic |
|----------|-------|
| [spec/audio_pipeline.md](spec/audio_pipeline.md) | Audio capture, resampling, file output, debugging |
| [spec/onboarding_flow.md](spec/onboarding_flow.md) | Permission handling, auto-advance behavior |
| [spec/window_management.md](spec/window_management.md) | SwiftUI window lifecycle, onboarding window |
| [spec/export_system.md](spec/export_system.md) | Export architecture, external tool integration, data formats |
| [spec/diagnostic_logging.md](spec/diagnostic_logging.md) | Diagnostic logging system, debug info panel |

---

## File: Info.plist Entries

```xml
<key>LSUIElement</key>
<true/>
<key>NSAudioCaptureUsageDescription</key>
<string>Muesli needs System Audio Recording access to capture audio from meeting apps like Zoom, Teams, and Google Meet.</string>
<key>NSScreenCaptureUsageDescription</key>
<string>Muesli needs Screen Recording access to capture audio from meeting apps like Zoom, Teams, and Google Meet.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Muesli needs Microphone access to capture your voice during meetings.</string>
```

---

## Dependencies

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.15.0")
]
```

### System Frameworks

- SwiftUI
- AVFoundation
- CoreMedia
- CoreAudio
- AudioToolbox

---

## Future Enhancements (Post-MVP)

1. **Mix audio to single file** - Combine system + mic audio into one M4A file
2. ✅ **Transcript reprocessing** - Re-process recordings with different models via context menu
3. **Searchable transcript history** - Browse and search past recordings
4. **Export formats** - SRT subtitles, plain text, JSON
5. **Keyboard shortcuts** - Global hotkey to start/stop recording
6. **Calendar integration** - Auto-name meetings from calendar events
7. **Selective transcription** - Option to transcribe only post-recording (save CPU)
8. **Advanced diarization** - Distinguish multiple remote speakers (beyond "Them")

### Implemented Enhancements

**Transcript Reprocessing**:
- Right-click context menu on meetings allows reprocessing with any downloaded model
- Bulk reprocessing supported for multi-selected meetings
- Progress indicator shown during reprocessing

**Audio-Only Recording**:
- When no transcription model is downloaded, users can record audio without transcription
- Recording indicator shows "waveform.slash" icon to indicate transcription is unavailable
- Audio files are saved normally and can be reprocessed later when a model is available

---

## Success Criteria

The MVP is complete when:

1. ✓ App installs and launches on macOS 26+ with M-series chip
2. ✓ First-run onboarding guides user through permissions and model setup
3. ✓ Can detect and select from running meeting apps
4. ✓ Records audio from meeting app + microphone simultaneously
5. ✓ Displays real-time transcript with "Me" vs "Them" speaker labels
6. ✓ Saves audio.caf, microphone.caf, and transcript.md to organized folder structure
7. ✓ UI is clean, minimal, and feels native to macOS
8. ✓ Can be shared with teammates for testing
