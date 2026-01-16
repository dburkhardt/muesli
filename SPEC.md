# Muesli - Software Design Specification

## Overview

**Muesli** is a local-first meeting transcription app for macOS. It captures audio from video conferencing apps (Zoom, Teams, Google Meet) along with microphone input, transcribes in real-time using on-device AI (WhisperKit), and saves both the audio recording and transcript for later use.

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
2. User is guided through granting Screen Recording permission
3. User is guided through granting Microphone permission
4. User downloads or selects an existing WhisperKit transcription model
5. Once setup is complete, onboarding finishes
6. App transitions to menu bar mode (window closes, icon appears in menu bar)

### Starting a Recording

1. User clicks menu bar icon → "New Recording" (opens a new session window)
2. In the session window, user sees "Ready to Record" with an app picker dropdown
3. User selects the meeting app to capture audio from (Zoom, Chrome, etc.)
4. User optionally enters a meeting title
5. User clicks "Start Recording"
6. Window transitions to recording state showing live transcript
7. Menu bar shows recording status with "Stop Recording" option

### During Recording

1. Main window displays transcript updating in real-time
2. User can optionally enter a meeting title in the text field at top
3. User can minimize/hide the window and continue recording
4. Menu bar dropdown shows "Stop Recording" option

### Stopping a Recording

1. User clicks "Stop Recording" in menu bar or session window
2. Recording is saved to `~/Library/Application Support/Muesli/Recordings/YYYY-MM-DD_HH-MM_[UUID]/`
   - Folder name uses timestamp + UUID for uniqueness (e.g., `2026-01-15_14-30_A1B2C3D4-E5F6-7890-ABCD-EF1234567890`)
   - Meeting title is stored in `transcript.md` header, not in folder name
   - This ensures stable folder names even when titles change, supporting future history features
   - Using Application Support instead of Documents avoids permission prompts and follows macOS best practices
3. Folder contains `audio.caf`, `microphone.caf`, and `transcript.md`
4. Session window shows "Recording Saved!" completion state with:
   - "Open in Finder" button to view saved files
   - "New Recording" button to open a fresh session window
5. Completed session windows remain open for transcript review
6. User can close old windows manually when done

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
│  │  MenuBarExtra   │  │    WindowGroup (sessions)   │  │
│  │  (quick access) │  │  ┌─────────────────────┐    │  │
│  └─────────────────┘  │  │  SessionWindowView  │    │  │
│                       │  │  (per-window state) │    │  │
│                       │  └─────────────────────┘    │  │
│                       └─────────────────────────────┘  │
│                              │                          │
│         ┌────────────────────┼────────────────────┐    │
│         ▼                    ▼                    ▼    │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────┐ │
│  │MuesliViewModel│    │RecordingSession│   │MainWindow│ │
│  │ (app state)  │    │ (per-window)  │   │  (view)  │ │
│  └──────────────┘    └──────────────┘    └──────────┘ │
│         │                                              │
│         ▼                                              │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐   │
│  │AudioCapture  │ │Transcription │ │ FileOutput   │   │
│  │  Service     │ │   Service    │ │   Service    │   │
│  └──────────────┘ └──────────────┘ └──────────────┘   │
└─────────────────────────────────────────────────────────┘
```

**Multi-Window Architecture**: Each recording session gets its own window. The `MuesliViewModel` holds shared app state (detected apps, permissions, services), while `RecordingSession` holds per-window state (meeting title, transcript, recording status). Completed sessions remain open for review; "New Recording" opens a fresh window.

### State Architecture

**Delegation Pattern** (implemented):

MuesliViewModel acts as a coordinator that delegates state management to focused managers:

```
MuesliViewModel (Coordinator)
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
├── RefinementCoordinator (owns refinement state)
│   ├─ showRefineSheet: Bool
│   ├─ meetingBeingRefined: MeetingHistoryItem?
│   ├─ canRefineTranscripts: Bool
│   └─ showOriginalTranscript tracking per meeting
│
└── Recording Coordination (ViewModel keeps)
    ├─ activeSession: RecordingSession?
    ├─ Audio/Transcription/FileOutput Services
    ├─ Real-time audio callbacks (nonisolated(unsafe))
    └─ Recording lifecycle state machine
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

The audio pipeline uses a parallel fork architecture with separate files for system and microphone audio:

```
SCStream (ScreenCaptureKit)
    │
    ├─────────────────────────────────┐
    │                                 │
    ▼                                 ▼
System Audio                    Microphone Audio
(from meeting app)              (macOS 15+ only)
    │                                 │
    ▼                                 ▼
CMSampleBuffer                  CMSampleBuffer
    │                                 │
    ├──────────┐                      ├──────────┐
    │          │                      │          │
    ▼          ▼                      ▼          ▼
AVAssetWriter  PCM Buffer       AVAssetWriter  PCM Buffer
(audio.caf)       │             (microphone.caf)  │
                  │                               │
                  └───────────┬───────────────────┘
                              │
                              ▼
                         WhisperKit
                         (transcribe)
                              │
                              ▼
                       Update ViewModel
                        transcriptText
```

**Note**: System audio and microphone audio are saved to separate CAF files because:
- They have different sample rates (48kHz vs 24kHz) and channel counts (stereo vs mono)
- CAF format doesn't support multiple audio tracks
- Separate files allow flexible post-processing (mixing is a post-MVP enhancement)

### Meeting App Detection

Use `NSWorkspace` to detect running applications, filter for known meeting apps:

```swift
let meetingAppBundleIDs = [
    "us.zoom.xos",           // Zoom
    "com.microsoft.teams",   // Microsoft Teams
    "com.google.Chrome",     // Google Meet (runs in Chrome)
    "com.apple.Safari",      // Google Meet (Safari)
    "com.microsoft.edgemac"  // Teams/Meet in Edge
]
```

For browser-based meetings (Google Meet), we capture the browser's audio. The user selects which app to capture.

---

## UI Specifications

### Menu Bar

**Icon**: Simple waveform or "M" glyph, 18x18 points

**Dropdown (idle state)**:
```
┌─────────────────────────┐
│ Start Recording     ▶  │  (submenu with app list)
├─────────────────────────┤
│ Open Muesli             │
├─────────────────────────┤
│ Preferences...          │
│ Quit Muesli             │
└─────────────────────────┘
```

**Dropdown (recording state)**:
```
┌─────────────────────────┐
│ ● Recording (02:34)     │
│ Stop Recording          │
├─────────────────────────┤
│ Open Muesli             │
├─────────────────────────┤
│ Quit Muesli             │
└─────────────────────────┘
```

### Main Window

**Size**: Contextual based on view mode:
- **Unified list view** (no recording, no meeting selected): 420pt wide × 600pt tall
- **Split view** (recording active or meeting selected): 750-900pt wide × 650pt tall

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

**Size**: 500pt wide × 400pt tall (fixed)

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

### Why Application Support?

1. **No permission prompts** - Application Support doesn't require user authorization
2. **Appropriate for app data** - Documents is for user-created files, not app-generated data
3. **Standard macOS convention** - Follows Apple's Human Interface Guidelines
4. **Clean separation** - App data stays organized and doesn't clutter user folders

---

## Implementation Phases

### Phase 0: Project Setup

**Goal**: Create Xcode project with all dependencies, verify build works.

**Tasks**:
1. Create new macOS App project in Xcode
   - Product Name: Muesli
   - Organization Identifier: (your identifier)
   - Interface: SwiftUI
   - Language: Swift
   
2. Configure project settings:
   - Set deployment target to macOS 14.0
   - Add `LSUIElement = YES` to Info.plist (hides dock icon)
   - Add `LSBackgroundOnly = NO` (we have a window too)
   - Add privacy descriptions to Info.plist:
     - `NSScreenCaptureUsageDescription`: "Muesli needs Screen Recording access to capture audio from meeting apps."
     - `NSMicrophoneUsageDescription`: "Muesli needs Microphone access to capture your voice during meetings."
   
3. Add Swift Package dependencies:
   - WhisperKit: `https://github.com/argmaxinc/WhisperKit.git` (from: "0.9.0")
   
4. Create folder structure as defined in AGENTS.md

6. Verify project builds successfully

**Checkpoint**: Run the app, see default SwiftUI window, no errors.

---

### Phase 1: Menu Bar Shell + Main Window

**Goal**: Create the app structure with menu bar and main window (no recording yet).

**Tasks**:

1. **Create MuesliApp.swift** with both scenes:
   ```swift
   @main
   struct MuesliApp: App {
       @State private var viewModel = MuesliViewModel()
       
       var body: some Scene {
           MenuBarExtra {
               MenuBarView(viewModel: viewModel)
           } label: {
               Image(systemName: "waveform")
           }
           
           Window("Muesli", id: "main") {
               MainWindow(viewModel: viewModel)
           }
           .defaultSize(width: 500, height: 600)
       }
   }
   ```

2. **Create MuesliViewModel.swift** with basic state:
   - Recording state enum
   - Meeting title string
   - Placeholder transcript text
   - Mock list of meeting apps

3. **Create MenuBarView.swift**:
   - "Start Recording" button (disabled for now)
   - "Open Muesli" button (opens main window)
   - "Quit" button
   - Show recording state when recording

4. **Create MainWindow.swift**:
   - Title text field at top
   - Scrollable transcript area
   - Recording indicator (red dot)
   - Stop button (hidden when not recording)
   - Apply Granola-inspired styling (clean, minimal)

5. **Configure LSUIElement** properly:
   - App should not appear in Dock
   - Menu bar icon should persist
   - Main window should be openable

6. **Add launch at login capability** (can be a future preference, stub for now)

**Checkpoint**: 
- App launches to menu bar only (no dock icon)
- Click menu bar icon shows dropdown
- "Open Muesli" opens the main window
- Main window has title field and transcript area
- Can quit from menu bar

---

### Phase 2: Audio Capture

**Goal**: Capture audio from a selected app + microphone, save to disk.

**Tasks**:

1. **Create AudioCaptureService.swift**:
   - Use ScreenCaptureKit's `SCStream`
   - Create `SCContentFilter` for selected application
   - Configure `SCStreamConfiguration`:
     - `capturesAudio = true`
     - `excludesCurrentProcessAudio = true`
     - `channelCount = 2`
     - `sampleRate = 48000`
   - Add stream outputs for `.audio` and `.microphone` (macOS 15+)
   - Implement `SCStreamOutput` protocol to receive `CMSampleBuffer`

2. **Create meeting app detection**:
   - Query `NSWorkspace.shared.runningApplications`
   - Filter for known meeting app bundle IDs
   - Update `availableMeetingApps` in ViewModel

3. **Implement parallel pipeline architecture**:
   - On receiving CMSampleBuffer in delegate:
     - Forward to AVAssetWriter (for disk)
     - Convert to PCM buffer (for future transcription)
   - Store PCM buffers in a ring buffer for Phase 3

4. **Create FileOutputService.swift**:
   - Set up two AVAssetWriters with Linear PCM (CAF format)
   - System audio: 48kHz, stereo, Float32 → `audio.caf`
   - Microphone: 24kHz, mono, Float32 → `microphone.caf`
   - Create output directory with timestamp and UUID (e.g., `YYYY-MM-DD_HH-MM_[UUID]`)
   - Handle start/stop writing
   - Finalize files on recording stop

5. **Wire up Start/Stop in ViewModel**:
   - Start: Request permissions → Start SCStream → Start AVAssetWriter
   - Stop: Stop SCStream → Finalize AVAssetWriter → Save files

6. **Update MenuBarView**:
   - Show detected apps in submenu
   - Enable "Start Recording" when an app is selected

7. **Handle permissions**:
   - Check `CGPreflightScreenCaptureAccess()` for screen recording
   - Check `AVCaptureDevice.authorizationStatus(for: .audio)` for microphone
   - Request if not granted

**Checkpoint**:
- Can select a running meeting app from menu bar
- Click "Start Recording" begins capture
- Menu bar shows recording indicator
- Click "Stop Recording" ends capture
- Two audio files saved to `~/Library/Application Support/Muesli/Recordings/`:
  - `audio.caf` (system audio) plays back correctly
  - `microphone.caf` (mic audio) plays back correctly
- Both files preview with QuickLook (spacebar)

---

### Phase 2.5: Onboarding + Model Setup

**Goal**: First-run experience that guides user through permissions and WhisperKit model setup.

**Tasks**:

1. **Create OnboardingView.swift** with multi-step flow:
   - **Welcome Screen**: Brief explanation of what Muesli does, "Get Started" button
   - **Screen Recording Screen**: Explain why needed, "Open System Settings" button, status indicator
   - **Microphone Screen**: Explain why needed, "Grant Access" button, status indicator
   - **Model Setup Screen**: Download or select existing WhisperKit model

2. **Implement permission status tracking**:
   - Poll permission status while onboarding screens are visible
   - Update UI to show checkmark when permission granted
   - Enable "Continue" button only when permission confirmed

3. **Implement model download/selection**:
   - Option A: "Download Model" with progress indicator (~150MB)
   - Option B: "Use Existing Model" file picker for users who have it
   - Model selection dropdown (base, small, medium - default: base)
   - Store model in app's Application Support directory

4. **Create ModelManager utility**:
   - Check if model exists locally
   - Download model from WhisperKit repo
   - Track download progress
   - Validate downloaded model

5. **Integrate onboarding into MuesliApp**:
   - Check `hasCompletedOnboarding` in UserDefaults on launch
   - If false, show onboarding window instead of menu bar
   - On completion, set flag and transition to menu bar mode

6. **Store onboarding state**:
   - `hasCompletedOnboarding: Bool` in UserDefaults
   - `selectedModelName: String` in UserDefaults

**Checkpoint**:
- Fresh install shows onboarding window (not menu bar)
- Can navigate through all onboarding screens
- Screen Recording permission can be granted via flow
- Microphone permission can be granted via flow
- Model downloads successfully with progress indicator
- Can point to existing model file
- After completion, app transitions to menu bar mode
- Subsequent launches skip onboarding

**Status**: ✅ COMPLETE

**Implementation Notes**:
- Onboarding window created manually via `NSWindow` + `NSHostingController` in `AppDelegate` for reliable opening
- Multi-model support: Users can download multiple models (tiny, base, small, medium, large-v3)
- Active model picker allows switching between downloaded models
- Model deletion feature added for managing storage
- Build script resets UserDefaults (`defaults delete com.muesli.app`) along with TCC for clean debug builds
- WhisperKit progress reports in ~5% increments; UI uses linear progress bar for smoother feedback
- Model ordering: All model selection UIs (active model picker, reprocess menus) display models in canonical enum order (Tiny → Base → Small → Medium → Large v3 → Large v3 Turbo) to match the download list order. Use `ModelManager.downloadedModelsOrdered` for consistent ordering.

**Onboarding Auto-Advance Behavior**:
When the user quits and reopens the app during onboarding, the `advanceBasedOnPermissions()` function automatically advances to the appropriate step based on granted permissions:
- If screen recording is granted but microphone is not → auto-advance to microphone permission page
- If both permissions are granted → auto-advance to model setup or LLM setup
- The user must manually click "Continue" to advance from the welcome screen (no auto-advance from welcome)

**Window Focus Behavior**:
After the user interacts with the system microphone permission dialog (triggered by `AVCaptureDevice.requestAccess(for: .audio)`), the onboarding window automatically brings itself back to the front via `AppDelegate.bringOnboardingWindowToFront()`. This ensures a smooth UX where the onboarding window doesn't get lost behind other windows after granting permission.

---

### Phase 3: Real-Time Transcription

**Goal**: Display live transcript with "Me" vs "Them" speaker labels as audio is captured.

**Dual-Stream Approach**: Both system audio (meeting participants) and microphone audio (user) are transcribed separately, with speaker labels applied based on source.

**Transcript Format**:
```markdown
# Team Standup
2026-01-06 10:30

## Transcript

[00:05] **Them**: Good morning everyone, let's get started.
[00:12] **Me**: Hey, thanks for setting this up.
[00:18] **Them**: Sure thing. So first item on the agenda...
```

**Tasks**:

1. **Create TranscriptionService.swift**:
   - Initialize WhisperKit with selected model (from onboarding)
   - Accept PCM audio buffers with source identifier (system vs mic)
   - Implement streaming transcription with chunking (5-10 second windows)
   - Return transcript segments with timestamps and speaker labels
   - Handle overlap for better accuracy

2. **Create AudioResampler utility**:
   - Convert system audio: 48kHz stereo → 16kHz mono
   - Convert mic audio: 24kHz mono → 16kHz mono
   - WhisperKit requires 16kHz mono Float32 input

3. **Implement parallel audio feeding**:
   - Fork audio buffers from AudioCaptureService to both:
     - FileOutputService (save to disk)
     - TranscriptionService (real-time transcription)
   - Process system and mic streams alternately to avoid GPU contention
   - Use sliding window approach with overlap

4. **Update ViewModel with speaker-labeled transcript**:
   - Merge "Me" and "Them" segments chronologically
   - Format with timestamps and speaker labels
   - Update `transcriptText` property on main actor

5. **Update MainWindow**:
   - Display live transcript in scrollable view
   - Style "Me" vs "Them" differently (e.g., alignment or color)
   - Auto-scroll to bottom as new text arrives
   - Show timestamps inline with text

6. **Handle transcription on background thread**:
   - WhisperKit processing should not block UI
   - Use Swift concurrency (Task, async/await)
   - Buffer management for smooth processing

7. **Save transcript to file**:
   - Update FileOutputService to write transcript.md
   - Include meeting title and date at top
   - Include speaker labels in saved format

**Checkpoint**:
- Start recording with a test audio source + speaking into mic
- See both "Me" and "Them" segments appear in transcript
- Segments appear in chronological order
- Timestamps accurate to within ~5 seconds
- Transcript saved with speaker labels to transcript.md
- Transcription doesn't cause noticeable UI lag

**Status**: ✅ COMPLETE

**Implementation Notes**:
- `TranscriptionService` uses `OSAllocatedUnfairLock` for thread-safe buffer management (CMSampleBuffer is not Sendable)
- Audio resampling handled internally: 48kHz stereo → 16kHz mono (system), 24kHz mono → 16kHz mono (mic)
- Model validation at recording start: checks `config.json` exists before initializing WhisperKit
- `MuesliViewModel.modelPath` is a computed property that reads from `modelManager.activeModelPath`
- Transcript segments appended via `RecordingSession.appendTranscriptSegment()` with speaker labels

---

### Phase 4: Polish & Refinement

**Goal**: Polish UI, handle edge cases, add preferences.

**Tasks**:

1. **Add meeting title prompt**:
   - When stopping recording, if title is empty, show prompt
   - Allow skipping (defaults to "Meeting")
   - Use sheet presentation in main window

2. **Polish UI**:
   - Refine typography and spacing
   - Add subtle animations (recording pulse, transcript fade-in)
   - Ensure dark mode support works correctly
   - Add app icon and menu bar icon

3. **Handle edge cases**:
   - Meeting app quits during recording → stop gracefully, save what we have
   - Permission revoked during recording → show error, stop
   - Disk full → show error, stop cleanly
   - WhisperKit model download fails → show error, allow retry

4. **Add Preferences**:
   - WhisperKit model selection (base, small, medium)
   - Output directory location
   - Launch at login toggle

5. **Testing and bug fixes**:
   - Test with real Zoom, Teams, Meet calls
   - Test permission flows on fresh account
   - Test long recordings (30+ minutes)
   - Test with various audio qualities

**Checkpoint**:
- Recording flow is polished and reliable
- Edge cases handled gracefully
- Preferences accessible and functional
- App feels professional and minimal

---

## File: Info.plist Entries

```xml
<key>LSUIElement</key>
<true/>
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
    .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
]
```

### System Frameworks

- SwiftUI
- ScreenCaptureKit
- AVFoundation
- CoreMedia

---

## Future Enhancements (Post-MVP)

1. **Mix audio to single file** - Combine system + mic audio into one M4A file
2. **Post-recording refinement** - Re-process with large-v3 model for better accuracy
3. **Searchable transcript history** - Browse and search past recordings
4. **Export formats** - SRT subtitles, plain text, JSON
5. **Keyboard shortcuts** - Global hotkey to start/stop recording
6. **Calendar integration** - Auto-name meetings from calendar events
7. **Selective transcription** - Option to transcribe only post-recording (save CPU)
8. **Advanced diarization** - Distinguish multiple remote speakers (beyond "Them")

---

## Success Criteria

The MVP is complete when:

1. ✓ App installs and launches on macOS 14+ with M-series chip
2. ✓ First-run onboarding guides user through permissions and model setup
3. ✓ Can detect and select from running meeting apps
4. ✓ Records audio from meeting app + microphone simultaneously
5. ✓ Displays real-time transcript with "Me" vs "Them" speaker labels
6. ✓ Saves audio.caf, microphone.caf, and transcript.md to organized folder structure
7. ✓ UI is clean, minimal, and feels native to macOS
8. ✓ Can be shared with teammates for testing
