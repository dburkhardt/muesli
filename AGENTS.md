# AGENTS.md — Muesli (macOS meeting transcription)

Meeting transcription for macOS: captures audio (Zoom/Teams/Meet) + mic, real-time transcription via WhisperKit, saves `audio.caf` + `microphone.caf` + `transcript.md`.

**Authoritative docs**: `SPEC.md` (product spec + phases) · This file (architecture + commands + pitfalls)
**Note for agents**: Additional flow-specific documentation lives in the `spec/` folder. If you are doing a comprehensive architecture review, read those documents as well.

## Quick Reference

| Aspect | Value |
|--------|-------|
| Platform | macOS 14+ (Sonoma) |
| Language | Swift 6 |
| UI | SwiftUI with `@Observable` |
| Architecture | `MuesliViewModel` (app state) + `RecordingSession` (per-recording) |
| Audio | ScreenCaptureKit |
| Transcription | WhisperKit |
| Package manager | Swift Package Manager |

## Working Rules

1. **Follow SPEC.md phases** — one at a time, verify checkpoint before proceeding
2. **Small diffs, compile often** — keep the app buildable at all times
3. **Check in frequently** — confirm approach before significant work; report progress at milestones
4. **Native patterns** — Swift 6 concurrency, `@Observable`, one type per file
5. **UI principle** — "Granola-inspired": minimal, clean, fast

## Commands

**Build & Launch** (main branch):
```bash
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
killall Muesli 2>/dev/null
xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug build 2>&1 | tee "build-${TIMESTAMP}.txt"
open ~/Library/Developer/Xcode/DerivedData/Muesli-*/Build/Products/Debug/Muesli.app
```

**For feature branches**, replace `Muesli` with `Muesli-<branch-suffix>` (see Branch Development below).

**Other commands**:
- Test: `xcodebuild ... test 2>&1 | tee "test-${TIMESTAMP}.txt"`
- Clean: `xcodebuild ... clean`
- Reset permissions: `tccutil reset ScreenCapture com.muesli.app && tccutil reset Microphone com.muesli.app`

**Efficient workflows**: Save build/test output once with `| tee`, then grep the file. Never re-run to extract different info.

## Branch Development

When using git worktrees for parallel development, each branch needs a unique bundle ID.

**Why**: macOS caches apps by bundle ID. Unique IDs enable side-by-side testing and correct TCC permissions.

**Setup checklist**:
1. Get branch: `git branch --show-current`
2. Sanitize name: `feature/foo-bar` → `feature-foo-bar` (slashes → dashes, ~25 chars max)
3. In `project.pbxproj`, update BOTH Debug and Release:
   - `PRODUCT_BUNDLE_IDENTIFIER = com.muesli.app.<branch-suffix>;`
   - `PRODUCT_NAME = "Muesli-<branch-suffix>";`
4. Update TCC reset script in same file to use `com.muesli.app.<branch-suffix>`
5. Commit: `git commit -m "Configure bundle ID for branch: <branch>"`
6. Push: `git push -u origin <branch>`

**main branch**: Always `com.muesli.app` (no suffix). Never commit bundle ID changes to main.

**Cleanup after merge**:
```bash
killall Muesli-<suffix> 2>/dev/null
rm -rf ~/Library/Developer/Xcode/DerivedData/Muesli-*/Build/Products/Debug/Muesli-<suffix>.app
tccutil reset ScreenCapture com.muesli.app.<suffix> 2>/dev/null || true
tccutil reset Microphone com.muesli.app.<suffix> 2>/dev/null || true
```

**Troubleshooting**: If bundle ID doesn't match branch, verify with `grep PRODUCT_BUNDLE_IDENTIFIER project.pbxproj | head -1` and reconfigure.

## Architecture

### App Structure
- `MuesliApp` — MenuBarExtra + single main Window
- **Single-window model**: Shows `UnifiedHistoryView` (idle) or split view (recording/viewing)
- **Contextual sizing**: 420px for list, 750-900px for split view

### State Management (Delegation Pattern)
```
SwiftUI Views → MuesliViewModel (coordinator)
                    ├── RecordingController (recording lifecycle, audio callbacks)
                    ├── PreferencesManager (output dir, settings)
                    ├── MeetingHistoryManager (history list, selection)
                    ├── RefinementCoordinator (LLM refinement state)
                    └── Services (Audio, Transcription, FileOutput, AEC)
```

ViewModel delegates recording operations to RecordingController. Views observe only ViewModel.

### Key Types
- `RecordingSession` — active recording state, timer, transcript
- `MeetingHistoryItem` — past meeting (title, date, directory, lazy-loaded transcript)
- `ModelManager` — WhisperKit model download/selection, persists to UserDefaults

### Audio Pipeline
```
System Audio: SCStream → AVAssetWriter (audio.caf) + resample 16kHz → WhisperKit
Microphone:   AVAudioEngine → AVAssetWriter (microphone.caf) + resample 16kHz → WhisperKit
```

Note: Microphone uses AVAudioEngine (not ScreenCaptureKit) to support user device selection.

## UI Patterns

- **Meeting list**: Single-click = show transcript; Double-click = dedicated window; Cmd/Shift-click = multi-select
- **Floating control bar**: Capsule shape, `.regularMaterial`, padding `.horizontal: 12, .vertical: 10`
- **Recording indicator**: Red dot + waveform + elapsed time (bottom-right when viewing past meeting)
- **Onboarding**: Always show welcome first; auto-advance only when ALL permissions granted

## Output Contract

Recordings saved to: `~/Library/Application Support/Muesli/Recordings/YYYY-MM-DD_HH-MM_[UUID]/`
- `audio.caf` — system audio (48kHz stereo Float32 LPCM)
- `microphone.caf` — mic audio (48kHz stereo Float32 LPCM)
- `transcript.md` — Markdown with timestamps and speaker labels

## Known Pitfalls

### TCC Permissions
`CGPreflightScreenCaptureAccess()` unreliable with ad-hoc signing. Use `PermissionManager.checkScreenRecordingPermissionAsync()` which uses `SCShareableContent`. Only for permission checking—not app detection (triggers prompt).

### Audio Sample Rates (CRITICAL)
**If transcription outputs gibberish, check sample rates first!** WhisperKit requires 16kHz. Both system audio (ScreenCaptureKit) and microphone (AVAudioEngine) capture at 48kHz. Use `TranscriptionService.resampleToWhisperFormat()`:
```swift
// System: 48kHz stereo → 16kHz mono
resampleToWhisperFormat(buffer, sourceSampleRate: 48000, sourceChannels: 2)
// Mic: 48kHz mono → 16kHz mono  
resampleToWhisperFormat(buffer, sourceSampleRate: 48000, sourceChannels: 1)
```

### ScreenCaptureKit
- Display-based `SCContentFilter` required for audio; window-based doesn't work
- We use AVAudioEngine for microphone instead of SCK's `captureMicrophone` (supports device selection)
- `CMSampleBuffer` not Sendable — use `OSAllocatedUnfairLock`, not actor isolation

### Meeting App Detection
Do NOT use `SCShareableContent` for app detection — triggers permission prompts. Use `NSWorkspace.shared.runningApplications`.

### WhisperKit
Progress callback requires `@Sendable`; use `Task { @MainActor }` for UI updates.

### SwiftUI
- `openWindow(id:)` makes new window key immediately — capture references BEFORE opening
- Gesture order: `.onTapGesture(count: 2)` before `.onTapGesture(count: 1)`

### ModelManager
Single source of truth. ViewModel accesses via computed property. OnboardingView must use `viewModel.modelManager`.

### Onboarding Window
Use `NSWindow` + `NSHostingController` in AppDelegate. Don't auto-advance welcome screen. Poll permissions only on permission screens.

## Reference

**Dependencies**:
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — on-device speech-to-text
- ScreenCaptureKit — system framework for audio capture

**Testing**: Use Zoom/Meet/Teams or QuickTime Player. Verify permissions, recording cycles, transcript accuracy.

**Reference projects**: Azayaka (menu bar + SCK), WhisperKit Sample, Apple's ScreenCaptureKit Sample
