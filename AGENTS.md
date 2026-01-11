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

## Branch-Based Parallel Development

When developing features in parallel using git worktrees, each **branch** must have a unique app identity. Bundle IDs are tied to branch names (not worktree directories), enabling persistent feature versions across agent sessions while supporting side-by-side testing.

**Key concepts:**
- **Branches** = persistent feature work with stable bundle IDs
- **Worktrees** = ephemeral agent workspaces (directories come and go)
- **Bundle IDs** = follow branch names across agent sessions
- **Git safety** = same branch can't exist in multiple worktrees (prevents conflicts)

### Why This Is Required

macOS caches app locations by bundle identifier. Bundle IDs must be unique per branch to enable:
- Testing multiple feature branches side-by-side
- Bundle ID persistence across agent sessions (new worktree, same branch = same bundle ID)
- Correct system dialog behavior ("Quit & Reopen" launches the right version)
- Clean TCC permission separation between feature branches
- Predictable app identification in menu bar and System Settings

### Setting Up a Worktree

When starting work, you'll either check out an existing branch or create a new one. The bundle ID configuration follows the branch.

#### Option A: Check Out Existing Branch (Most Common)

When continuing work on an existing feature branch:

```bash
# Step 1: Fetch latest branches from remote
git fetch

# Step 2: List available branches
git branch -r | grep feature

# Step 3: Create worktree for existing branch
# Replace <path> with your worktree directory (e.g., /tmp/cursor-xyz)
# Replace <branch-name> with the branch (e.g., feature-transcription)
git worktree add <path> origin/<branch-name>

# Step 4: Navigate to worktree
cd <path>

# Step 5: Verify bundle ID matches branch
# (Agent should do this automatically - see workflow in .cursorrules)
CURRENT_BRANCH=$(git branch --show-current)
BRANCH_SUFFIX=$(echo $CURRENT_BRANCH | sed 's/\//-/g')
grep "PRODUCT_BUNDLE_IDENTIFIER" Muesli.xcodeproj/project.pbxproj | head -1

# Should show: com.muesli.app.$BRANCH_SUFFIX (or com.muesli.app for main)
```

**Bundle ID is already configured** - the branch contains the correct configuration. You can build immediately after verification.

#### Option B: Create New Branch

When starting a new feature:

```bash
# Step 1: Create worktree with new branch
# Use descriptive branch name (feature-xyz, bugfix-abc)
git worktree add -b <branch-name> <path>

# Step 2: Navigate to worktree
cd <path>

# Step 3: Configure bundle ID based on branch name
# Get sanitized branch name (slashes → dashes)
BRANCH_SUFFIX=$(git branch --show-current | sed 's/\//-/g')
echo "Branch: $(git branch --show-current)"
echo "Bundle ID suffix: $BRANCH_SUFFIX"
```

**Step 4: Update `Muesli.xcodeproj/project.pbxproj`**

Search for and update these values in BOTH Debug and Release configurations:

```
# Find these lines (appear twice - once for Debug, once for Release):
PRODUCT_BUNDLE_IDENTIFIER = com.muesli.app;
PRODUCT_NAME = "$(TARGET_NAME)";

# Change to (using your branch suffix):
PRODUCT_BUNDLE_IDENTIFIER = com.muesli.app.<branch-suffix>;
PRODUCT_NAME = "Muesli-<branch-suffix>";
```

**Step 5: Update the TCC reset script**

In the same file, find the "Reset TCC Permissions" shell script and update the bundle IDs:

```bash
# Find:
tccutil reset ScreenCapture com.muesli.app
tccutil reset Microphone com.muesli.app
defaults delete com.muesli.app

# Change to:
tccutil reset ScreenCapture com.muesli.app.<branch-suffix>
tccutil reset Microphone com.muesli.app.<branch-suffix>
defaults delete com.muesli.app.<branch-suffix>
```

**Step 6: Commit configuration and push branch to remote**

After configuring the app identity, commit the changes and push the branch to remote:

```bash
# Stage the configuration changes
git add Muesli.xcodeproj/project.pbxproj

# Commit the configuration
git commit -m "Configure bundle ID for branch: <branch-name>"

# Push branch to remote (enables other agents to discover and work on it)
git push -u origin <branch-name>
```

**Important**: The branch MUST be pushed to remote after configuration so other agents can check it out and inherit the bundle ID.

#### Special Case: main Branch

When working on the `main` branch:
- Always use default `com.muesli.app` (no suffix)
- Never commit bundle ID changes to main
- This is the production configuration

### Build Commands for Branches

The build command varies based on your branch name. Replace `<branch-suffix>` with your sanitized branch name (slashes converted to dashes).

**Branch-specific build**:
```bash
# Kill, Build, and Launch (branch version)
killall Muesli-<branch-suffix> 2>/dev/null; xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug build -quiet && open ~/Library/Developer/Xcode/DerivedData/Muesli-*/Build/Products/Debug/Muesli-<branch-suffix>.app
```

**Examples**:

```bash
# Example: feature-transcription branch
killall Muesli-feature-transcription 2>/dev/null; xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug build -quiet && open ~/Library/Developer/Xcode/DerivedData/Muesli-*/Build/Products/Debug/Muesli-feature-transcription.app

# Example: bugfix-audio-sync branch
killall Muesli-bugfix-audio-sync 2>/dev/null; xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug build -quiet && open ~/Library/Developer/Xcode/DerivedData/Muesli-*/Build/Products/Debug/Muesli-bugfix-audio-sync.app

# Example: feature/llm-refinement branch (slashes become dashes)
killall Muesli-feature-llm-refinement 2>/dev/null; xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug build -quiet && open ~/Library/Developer/Xcode/DerivedData/Muesli-*/Build/Products/Debug/Muesli-feature-llm-refinement.app

# Example: main branch (no suffix)
killall Muesli 2>/dev/null; xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug build -quiet && open ~/Library/Developer/Xcode/DerivedData/Muesli-*/Build/Products/Debug/Muesli.app
```

### Best Practices for Branch-Based Development

- **Branch naming**: Use descriptive names that indicate purpose (`feature-transcription`, `bugfix-audio-sync`, `refactor-viewmodel`)
- **Bundle ID follows branch**: Bundle ID configuration is part of the branch, not the worktree directory
- **Check out existing branches**: Before creating a new branch, check if someone already started work on it (`git branch -r | grep feature-xyz`)
- **main stays clean**: Never commit bundle ID changes to main branch (always `com.muesli.app`)
- **Merge cleanup**: After merging feature branch to main, delete the feature branch. Bundle ID config goes with it.
- **Push frequently**: Other agents can check out your branch in a new worktree and continue your work
- **One branch = one worktree**: Git enforces this constraint (safety feature, not limitation)
- **Branch name sanitization**: Slashes become dashes (`feature/xyz` → `com.muesli.app.feature-xyz`)
- **Worktree monitoring**: Use `git worktree list` to see all active worktrees
- **Remote branch tracking**: Use `git push -u origin <branch>` to set upstream tracking on first push

### Git Worktree Constraints (By Design)

Git prevents checking out the same branch in multiple worktrees. This is **intentional** and provides important safety guarantees:

**Benefits:**
- Each branch has exactly one active worktree at a time
- No bundle ID conflicts possible (one branch = one bundle ID)
- No risk of simultaneous conflicting edits to the same branch
- Agents collaborate via push/pull workflow, not simultaneous editing
- Clear ownership: one agent working on a branch at a time

**Workflow:**
- To continue another agent's work: `git fetch` and check out their branch in a new worktree
- The bundle ID configuration is already in the branch - no reconfiguration needed
- To work on different features simultaneously: create separate branches with separate worktrees

### Cleaning Up After Merging (MANDATORY)

**⚠️ CRITICAL**: Before deleting a worktree, clean up app builds and permissions to prevent multiple menu bar icons, wrong app launches, and TCC confusion.

```bash
# 1. Kill running instances (replace <branch-suffix> with your branch name)
killall Muesli-<branch-suffix> 2>/dev/null; killall Muesli 2>/dev/null

# 2. Remove DerivedData
rm -rf ~/Library/Developer/Xcode/DerivedData/Muesli-*/Build/Products/Debug/Muesli-<branch-suffix>.app

# 3. Reset TCC permissions and UserDefaults
tccutil reset ScreenCapture com.muesli.app.<branch-suffix> 2>/dev/null || true
tccutil reset Microphone com.muesli.app.<branch-suffix> 2>/dev/null || true
defaults delete com.muesli.app.<branch-suffix> 2>/dev/null || true

# 4. Unregister from LaunchServices
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u ~/Library/Developer/Xcode/DerivedData/Muesli-*/Build/Products/Debug/Muesli-<branch-suffix>.app 2>/dev/null || true

# 5. Verify and remove worktree
ps aux | grep -i muesli | grep -v grep  # Should be empty
cd /path/to/repo && git worktree remove <worktree-path>
```

**Example for feature-transcription branch**:
```bash
killall Muesli-feature-transcription 2>/dev/null
rm -rf ~/Library/Developer/Xcode/DerivedData/Muesli-*/Build/Products/Debug/Muesli-feature-transcription.app
tccutil reset ScreenCapture com.muesli.app.feature-transcription 2>/dev/null || true
tccutil reset Microphone com.muesli.app.feature-transcription 2>/dev/null || true
defaults delete com.muesli.app.feature-transcription 2>/dev/null || true
```

### Verifying Your Setup

After configuring a branch, verify:
1. Build produces `Muesli-<branch-suffix>.app` (or `Muesli.app` for main branch)
2. Menu bar shows "Muesli-<branch-suffix>" when you hover over the icon
3. System Settings → Privacy → Screen Recording shows "Muesli-<branch-suffix>"
4. Bundle ID in project.pbxproj matches sanitized branch name
5. Only ONE Muesli icon appears in menu bar

**Quick verification commands**:
```bash
# Check current branch
git branch --show-current

# Check bundle ID configuration
grep "PRODUCT_BUNDLE_IDENTIFIER" Muesli.xcodeproj/project.pbxproj | head -1

# Check running Muesli processes
ps aux | grep -i muesli | grep -v grep
```

### Troubleshooting

**Multiple menu bar icons?**
```bash
# Kill all Muesli variants and check for stale processes
killall Muesli 2>/dev/null; killall Muesli-<branch-suffix> 2>/dev/null
ps aux | grep -i muesli
```

**"Quit & Reopen" launches wrong version?**
1. Check for multiple DerivedData folders: `ls ~/Library/Developer/Xcode/DerivedData/ | grep Muesli`
2. Remove all but your current branch's build
3. Re-register the correct app: `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f <path-to-correct-app>`

**Bundle ID doesn't match current branch?**

This happens when the bundle ID in `project.pbxproj` doesn't match your current branch name.

**Symptoms:**
- Build produces wrong app name (e.g., `Muesli-feature-a.app` when on branch `feature-b`)
- Menu bar shows wrong app name
- TCC permissions prompt for wrong app name

**Diagnosis:**
```bash
# Check current branch
CURRENT_BRANCH=$(git branch --show-current)
echo "Current branch: $CURRENT_BRANCH"

# Check bundle ID in project
BUNDLE_ID=$(grep 'PRODUCT_BUNDLE_IDENTIFIER' Muesli.xcodeproj/project.pbxproj | head -1)
echo "Bundle ID: $BUNDLE_ID"

# Calculate expected bundle ID
BRANCH_SUFFIX=$(echo $CURRENT_BRANCH | sed 's/\//-/g')
if [ "$CURRENT_BRANCH" = "main" ]; then
  echo "Expected: com.muesli.app (no suffix for main)"
else
  echo "Expected: com.muesli.app.$BRANCH_SUFFIX"
fi
```

**Common causes:**
- Checked out wrong branch (verify with user: "Is this the correct branch?")
- Bundle ID configured for different branch (stale configuration from previous work)
- New branch not yet configured (needs initial setup)
- Branch was renamed but bundle ID wasn't updated

**Fix:**
1. Confirm with user that current branch is correct
2. If correct branch, reconfigure bundle ID to match branch name (see "Setting Up a Worktree" → "Create New Branch")
3. If wrong branch, check out the correct branch
4. Commit and push bundle ID changes after reconfiguration

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
- **Floating control bar**: During recording, shows mic picker, transcription mode, stop button. Uses pill shape (Capsule) with `.regularMaterial` background.
- **Refinement control pane**: Post-meeting floating control pane shows loading indicator (animated magic wand) while refining, then toggle switch (magic wand icon for refined, document icon for original) after completion. Uses same pill shape styling as recording control bar.
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
- **CAF format**: Matches SCStream's native output, supports real-time writes. Separate files for system/mic (different sample rates).
- **ScreenCaptureKit**: Display-based `SCContentFilter` required for audio; window-based doesn't work. `captureMicrophone` requires macOS 15+.
- **CMSampleBuffer**: Not Sendable; use synchronous callbacks with `OSAllocatedUnfairLock`, not actor isolation.
- **Audio resampling**: WhisperKit requires 16kHz mono Float32. System (48kHz stereo) and mic (48kHz mono) must be resampled using `AVAudioConverter`. Deinterleave stereo before conversion.
- **Model management**: `ModelManager` is single source of truth; ViewModel accesses via computed property. Always check `config.json` exists before initializing WhisperKit.
- **UI patterns**: `openWindow(id:)` makes new window key immediately—capture references BEFORE opening. SwiftUI gesture order: `.onTapGesture(count: 2)` before `.onTapGesture(count: 1)`.

## Checkpoint discipline (important)
At the end of each phase:
- Run the build (and tests if present)
- Confirm the checkpoint criteria in `SPEC.md`
- Only then proceed to the next phase

If you are missing information (bundle ID list, Info.plist details, UI sizing, etc.), consult `SPEC.md` first.

## Documentation Updates

After completing work, evaluate if core docs need updates. Update:
- **AGENTS.md**: Technical constraints → "Known technical constraints"; pitfalls → "Common Pitfalls"; build/test changes → "Commands"
- **SPEC.md**: Phase requirements/checkpoints, architecture decisions, UI specs, output format
- **`.cursorrules`**: Agent workflow patterns, common mistakes

**Process**: Reflect → Categorize → Update appropriate section → Verify consistency. Be selective and concise.

## When you respond to the user
When you make changes:
- Summarize what you changed and why
- List files touched (including documentation if updated)
- Provide build/test commands you ran (or should be run)
- Call out any follow‑ups needed to meet the phase checkpoint

## Common Pitfalls

### TCC Permissions (Debug Builds)
- `CGPreflightScreenCaptureAccess()` unreliable with ad-hoc signing. Use `SCShareableContent.excludingDesktopWindows()` for permission checking (via `PermissionManager.checkScreenRecordingPermissionAsync()`). Only use for permission *checking*, not app detection (triggers prompt).

### Audio Sample Rate Debugging (CRITICAL)
**⚠️ If transcription outputs nonsense/gibberish, CHECK SAMPLE RATES FIRST!**

WhisperKit requires exactly 16kHz audio. ScreenCaptureKit provides 48kHz (system stereo, mic mono). Both must be resampled using `TranscriptionService.resampleToWhisperFormat()`:
```swift
// System: 48kHz stereo -> 16kHz mono
TranscriptionService.resampleToWhisperFormat(buffer, sourceSampleRate: 48000, sourceChannels: 2)
// Mic: 48kHz mono -> 16kHz mono
TranscriptionService.resampleToWhisperFormat(buffer, sourceSampleRate: 48000, sourceChannels: 1)
```

### Meeting App Detection
- Do NOT use `SCShareableContent.excludingDesktopWindows()` for app detection—triggers permission prompts. Use `NSWorkspace.shared.runningApplications` instead.

### WhisperKit
- Progress callback requires `@Sendable`; use `Task { @MainActor }` for UI updates. Progress reports in ~5% increments. Neural Engine auto-enabled on Apple Silicon.

### LLM Stitching & Refinement
- Auto-enabled when model downloaded. Ensure transcript loaded before refining (`loadTranscript(for:)` if needed). Show loading indicator immediately when `willRefine` is true. Store `originalTranscriptBlocks`/`originalTranscript` before refining for toggle.

### ModelManager Architecture
- Single source of truth for model state. ViewModel accesses via computed property (`modelPath`). OnboardingView must use `viewModel.modelManager`, not create own instance.

### Onboarding Window (SwiftUI)
- Use `NSWindow` + `NSHostingController` in `AppDelegate` (not SwiftUI `WindowGroup`). Capture window reference BEFORE calling `openWindow(id:)` if you need to close original. Don't auto-advance welcome screen. Poll permissions only on permission screens using `onChange(of: currentStep)`.

### UI Patterns
- Floating control panes: `Capsule()` shape, `.regularMaterial` background, padding `.horizontal: 12, .vertical: 10`, shadow `radius: 6, x: 0, y: 2`.

## Reference

### Key Dependencies
- **WhisperKit**: https://github.com/argmaxinc/WhisperKit (on-device speech-to-text, models: `base` for real-time)
- **ScreenCaptureKit**: System framework for audio capture (requires Screen Recording + Microphone permissions)

### Testing Notes
Test with Zoom/Meet/Teams calls or QuickTime Player. Verify permissions flow, recording cycles, and transcript accuracy.

### Reference Projects
- **Azayaka**: Menu bar app, ScreenCaptureKit patterns
- **WhisperKit Sample**: WhisperKit integration examples
- **Apple's ScreenCaptureKit Sample**: Official SCStream/SCContentFilter patterns
