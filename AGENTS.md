# AGENTS.md — Muesli (macOS meeting transcription)

Meeting transcription for macOS: captures audio (Zoom/Teams/Meet) + mic, real-time transcription via WhisperKit, saves `audio.caf` + `microphone.caf` + `transcript.md`.

**Authoritative docs**: `SPEC.md` (product spec + phases) · This file (architecture + commands + pitfalls)
**Note for agents**: Additional flow-specific documentation lives in the `spec/` folder. If you are doing a comprehensive architecture review, read those documents as well.

**Code signing & notarization**: App is signed with Developer ID and notarized by Apple when released via GitHub Actions. Credentials stored in repository secrets (never committed to git).

## Quick Reference

| Aspect | Value |
|--------|-------|
| Platform | macOS 26+ |
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
6. **Track future work** — when asked to "add a todo" or "note this for later", suggest creating a GitHub Issue and continue working
7. **Preserve debugging code** — do not remove print statements, Logger calls, or temporary debugging code without asking the user first

## Commands

**Build & Launch** (recommended):

The build takes 5-8 minutes. **Run with `nohup`** and monitor via log file:

```bash
# Step 1: Start the build with nohup (REQUIRED for long builds)
nohup ./scripts/build-and-launch.sh > /dev/null 2>&1 &

# Step 2: Check if build is still running
cat /tmp/muesli-build.lock  # Shows PID if running, missing if done

# Step 3: Find and monitor the log file
ls -t /tmp/muesli-build-*.log | head -1                          # Find latest log
tail -30 "$(ls -t /tmp/muesli-build-*.log | head -1)"            # View recent output
grep "Build & Launch Complete" /tmp/muesli-build-*.log           # Check if finished
grep "error:" "$(ls -t /tmp/muesli-build-*.log | head -1)"       # Check for errors
```

**Build completion indicators** in log file:
- `"Build & Launch Complete"` — Success, app is running
- `"Build Complete (--build-only)"` — Success, app not launched
- `"BUILD SUCCEEDED"` — xcodebuild finished successfully
- `"error:"` — Build failed, check log for details

**Build & Launch options**:
```bash
./scripts/build-and-launch.sh              # Deep clean + build (DEFAULT - always use this)
./scripts/build-and-launch.sh --build-only # Build without launching
./scripts/build-and-launch.sh --no-log     # Disable logging to file
./scripts/build-and-launch.sh --dry-run    # Show what would happen
```

**What the script does** (deep clean + logging by default):
- Logs all output to `/tmp/muesli-build-TIMESTAMP.log` (strips ANSI colors)
- Uses lock file `/tmp/muesli-build.lock` to prevent parallel builds
- Removes DerivedData, Launch Services cache, Swift PM cache, and module caches
- Runs `xcodebuild clean build` to ensure all code changes are compiled

**Advanced options** (rarely needed):
- `--preserve-caches` — Skip cache clearing (NOT recommended; stale caches cause confusing issues)
- `--incremental` — Use cached build (NOT recommended; may miss code changes)

**Other commands**:
- Test: `xcodebuild ... test 2>&1 | tee "/tmp/muesli-test-${TIMESTAMP}.txt"`
- Test with coverage: `./scripts/generate-coverage.sh`
- Clean: `xcodebuild ... clean`
- Reset permissions: `tccutil reset ScreenCapture com.muesli.app && tccutil reset Microphone com.muesli.app`
- Uninstall completely (interactive): `./scripts/uninstall.sh`
- Generate changelog: `git-cliff --latest --strip header,footer > CHANGELOG.md`
- Create DMG (modern): `./scripts/create-dmg-modern.sh [VERSION]`
- Create DMG (legacy): `./scripts/create-dmg.sh [VERSION]`

**Efficient workflows**: Save build/test output once with `| tee` to `/tmp/`, then grep the file. Never re-run to extract different info.

## Code Coverage

Muesli tracks code coverage to ensure comprehensive testing and guide development efforts.

**Coverage Tools**:
- Native Xcode coverage collection (built-in, zero-config)
- Codecov for reporting and trend tracking (free for open source)
- Coverage badge in README shows current status

**Coverage Thresholds**:
- **Overall project**: 70% minimum (baseline)
- **New code (PR diff)**: 80% minimum (enforced in CI)
- **Critical paths**: 90%+ target (audio, transcription, file I/O)

**Local Coverage Workflow**:
```bash
# Generate coverage report locally
./scripts/generate-coverage.sh

# View in Xcode:
# 1. Open Muesli.xcodeproj
# 2. Report Navigator (⌘9)
# 3. Select latest test run
# 4. Click 'Coverage' tab
```

**CI Integration**:
- Every PR shows coverage diff in comments
- Status check fails if diff coverage < 80%
- Coverage reports uploaded to Codecov automatically
- View trends at: https://codecov.io/gh/dburkhardt/muesli

**Priority Areas for Coverage**:
1. Controllers - RecordingController (core recording logic)
2. Services - AudioCaptureService, TranscriptionService, FileOutputService
3. Managers - ModelManager, MeetingHistoryManager, PreferencesManager
4. Coordinators - TranscriptionCoordinator, RefinementCoordinator
5. Views - Complex UI logic (lower priority than business logic)

## Release Process

### Creating a Release

Muesli uses automated GitHub Actions to build and publish releases. The process is triggered by git tags.

**Prerequisites**:
- All changes committed to `main` branch
- Tests passing
- Pre-release testing completed (see checklist below)
- Version number decided (follows [Semantic Versioning](https://semver.org/))

**Steps**:

1. **Update Version.xcconfig** (if not already updated):
   ```bash
   # Edit Version.xcconfig and set MARKETING_VERSION
   vim Version.xcconfig  # Change to desired version (e.g., 0.2.0)
   git add Version.xcconfig
   git commit -m "chore: Bump version to 0.2.0"
   git push origin main
   ```

2. **Create and push version tag**:
   ```bash
   # Create tag (must start with 'v')
   git tag v0.2.0
   
   # Push tag to trigger release workflow
   git push origin v0.2.0
   
   # Watch the build progress
   ./scripts/watch-release.sh
   ```

3. **Monitor GitHub Actions**:
   - Watch the "Release" workflow complete
   - Workflow will:
     - Cache dependencies for faster builds
     - Build app in Release configuration
     - Create DMG installer (tries modern script, falls back to legacy)
     - Generate release notes with git-cliff from conventional commits
     - Generate artifact attestation for supply chain security
     - Create GitHub Release with DMG asset
     - Update website with new version
     - Deploy to GitHub Pages

4. **Verify release**:
   - Check GitHub Releases page
   - Download DMG and test installation
   - Verify website shows correct version

### Version Numbering

Follow [Semantic Versioning](https://semver.org/) (MAJOR.MINOR.PATCH):

- **MAJOR** (1.0.0): Breaking changes, major new features
- **MINOR** (0.2.0): New features, backward compatible
- **PATCH** (0.1.1): Bug fixes, minor improvements

**Pre-release versions**: Use hyphenated suffix for testing:
- `0.2.0-alpha.1` — early testing
- `0.2.0-beta.1` — feature complete, testing
- `0.2.0-rc.1` — release candidate

### Pre-Release Testing Checklist

Before creating a release tag, verify:

**Build & Installation**:
- [ ] Clean build succeeds: `xcodebuild clean build`
- [ ] All tests pass: `xcodebuild test`
- [ ] Code coverage meets thresholds (≥70% overall)
- [ ] DMG creation succeeds: `./scripts/create-dmg-modern.sh` or `./scripts/create-dmg.sh`
- [ ] DMG installs on fresh macOS installation
- [ ] App launches without errors
- [ ] Gatekeeper bypass works (right-click → Open)
- [ ] Artifact attestation verifies: `gh attestation verify Muesli-vX.Y.Z.dmg --owner dburkhardt`

**Core Functionality**:
- [ ] Onboarding flow completes successfully
- [ ] Screen recording permission granted
- [ ] Microphone permission granted
- [ ] Whisper model downloads successfully
- [ ] System audio capture works (test with Zoom/Teams/Meet)
- [ ] Microphone capture works
- [ ] Real-time transcription appears correctly
- [ ] Recording stops cleanly
- [ ] Transcript saved to correct location
- [ ] Meeting history displays past recordings
- [ ] Search works in meeting history
- [ ] Transcript export works

**Edge Cases**:
- [ ] Multiple recordings in succession
- [ ] Recording during app restart
- [ ] Different Whisper models (tiny, base, small)
- [ ] Different microphone devices
- [ ] Long recordings (30+ minutes)
- [ ] No internet connection (on-device still works)

**UI/UX**:
- [ ] Menu bar icon displays correctly
- [ ] All windows resize properly
- [ ] Dark mode works correctly
- [ ] Keyboard shortcuts work
- [ ] No console errors or warnings

**Performance**:
- [ ] Memory usage reasonable during recording
- [ ] CPU usage reasonable during transcription
- [ ] No audio glitches or dropouts
- [ ] Transcription keeps up with real-time audio

### Manual Release (Workflow Dispatch)

If you need to create a release without pushing a tag:

1. Go to GitHub Actions → Release workflow
2. Click "Run workflow"
3. Enter version number (without 'v' prefix, e.g., `0.2.0`)
4. Click "Run workflow"

This is useful for:
- Testing the release workflow
- Creating builds from non-main branches
- Re-running failed releases

### Release Artifacts

Each release produces:
- **DMG file**: `Muesli-vX.Y.Z.dmg` (uploaded to GitHub Release)
- **SHA-256 checksum**: Included in release notes
- **Release notes**: Auto-generated from git log or CHANGELOG.md
- **Website update**: docs/download.html updated with new version

### Troubleshooting Releases

**Build fails in CI**:
- Check build logs in GitHub Actions
- Verify Xcode version matches (26.x on macos-26)
- Ensure all dependencies resolve correctly
- Test build locally first: `./scripts/create-dmg.sh`

**DMG not created**:
- Check scripts/create-dmg.sh has correct permissions
- Verify Version.xcconfig contains valid version
- Look for disk space issues in CI

**Website not updated**:
- Check git push permissions in workflow
- Verify GitHub Pages is enabled (Settings → Pages → Source: main/docs)
- Check for merge conflicts in docs/download.html

**Release not appearing**:
- Verify tag was pushed: `git ls-remote --tags origin`
- Check workflow triggered: GitHub Actions tab
- Verify GITHUB_TOKEN has contents:write permission

### Version History

See [CHANGELOG.md](CHANGELOG.md) for detailed version history and release notes.

## Branch Development

### Worktree Isolation (Optional)

Most branches work fine in the standard workspace. However, when you need **parallel development** (testing multiple branches simultaneously), each branch needs a unique bundle ID.

**Why**: macOS caches apps by bundle ID. Unique IDs enable side-by-side testing and correct TCC permissions.

### When to Use Worktree Isolation

**Use worktree config when**:
- Parallel development (testing multiple branches simultaneously)
- Long-lived feature branches
- Side-by-side comparison with main
- Need TCC permission isolation between branches

**Skip worktree config when**:
- Short-lived branches
- Quick fixes or hotfixes
- Single-branch workflow
- Not testing multiple builds simultaneously

### Agent Workflow: Creating New Branches

When a user asks to create a new branch, **always prompt**:

> "Should this branch need worktree isolation for parallel development? (yes/no)"

**If yes**: Create `.worktree-config.json` indicator file and apply bundle ID configuration
**If no**: Create standard branch, work normally in main workspace

### Worktree Indicator File

Branches that need worktree isolation include a `.worktree-config.json` file:

```json
{
  "needsWorktree": true,
  "suffix": "xxx",
  "bundleId": "com.muesli.app.xxx",
  "productName": "Muesli-xxx",
  "reason": "parallel development with main branch"
}
```

**Suffix naming**: Sanitize branch name to 3-letter code: `feature/foo-bar` → `foo` or use random 3-letter code.

### Setup Checklist (When Indicator Present)

1. Check if `.worktree-config.json` exists in branch root
2. If present, read suffix from file
3. In `project.pbxproj`, update BOTH Debug and Release:
   - `PRODUCT_BUNDLE_IDENTIFIER = com.muesli.app.<suffix>;`
   - `PRODUCT_NAME = "Muesli-<suffix>";`
4. Update TCC reset script in same file to use `com.muesli.app.<suffix>`
5. Commit: `git add .worktree-config.json project.pbxproj && git commit -m "Configure worktree isolation for branch"`
6. Push: `git push -u origin <branch>`

Alternatively, use the automated script: `./scripts/configure-worktree.sh`

**main branch**: Always `com.muesli.app` (no suffix). Never commit bundle ID changes to main.

### Cleanup After Merge

```bash
killall Muesli-<suffix> 2>/dev/null
rm -rf ~/Library/Developer/Xcode/DerivedData/Muesli-*/Build/Products/Debug/Muesli-<suffix>.app
tccutil reset ScreenCapture com.muesli.app.<suffix> 2>/dev/null || true
tccutil reset Microphone com.muesli.app.<suffix> 2>/dev/null || true
```

### Backward Compatibility

The project also supports `.cursorworktrees.json` (global config at repo root) for managing multiple worktrees. The configure script checks:
1. `.worktree-config.json` in branch (preferred, per-branch)
2. `.cursorworktrees.json` at repo root (legacy, global)

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
**Stable Code Signing Required**: The project uses `DEVELOPMENT_TEAM` in `project.pbxproj` to ensure stable code signatures. This makes `CGPreflightScreenCaptureAccess()` reliable and allows TCC permissions to persist across builds. Without `DEVELOPMENT_TEAM`, Xcode uses ad-hoc signing which changes the code signature on every build, causing:
- TCC permissions to reset after each rebuild
- `CGPreflightScreenCaptureAccess()` to return false incorrectly
- Random permission prompts during normal operation

**Permission Check APIs**:
- `CGPreflightScreenCaptureAccess()` — Now reliable with stable signing. Used as a gate in `AudioCaptureService` before `SCShareableContent` calls.
- `PermissionManager.checkScreenRecordingPermissionAsync()` — Uses `SCShareableContent` for authoritative check. Includes 5-minute caching to reduce prompt frequency.
- Do NOT use `SCShareableContent` for meeting app detection (triggers prompt). Use `NSWorkspace.shared.runningApplications` instead.

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

## Debugging Guidance

### Runtime Diagnostic Logs

Muesli includes a `DiagnosticLogger` that writes structured logs to disk for debugging release build issues.

**Log Location**: `~/Library/Application Support/Muesli/Logs/`

**File Format**: `muesli-YYYY-MM-DD.log` (one file per day, auto-rotates)

**Log Categories**:
- `BUILD` — Bundle ID, version, Info.plist keys (logged on app launch)
- `PERMISSION` — Permission checks/requests with status values
- `ONBOARDING` — Step transitions and button tap events
- `APP` — General app events

**Accessing Logs**:
```bash
# View today's log
cat ~/Library/Application\ Support/Muesli/Logs/muesli-$(date +%Y-%m-%d).log

# Search for permission-related entries
grep PERMISSION ~/Library/Application\ Support/Muesli/Logs/*.log

# Watch log in real-time
tail -f ~/Library/Application\ Support/Muesli/Logs/muesli-$(date +%Y-%m-%d).log
```

**In-App Access**: Menu Bar → Debug Info... (available during both onboarding and normal operation)

**Log Retention**: 7 days (auto-cleanup on app launch)

**Privacy Policy**: Logs contain only build/permission metadata. NO user content (transcripts, meeting titles, file paths).

### Before Starting a Debug Session

**Check the debug log knowledge base first**: [`docs/debug-logs/`](docs/debug-logs/)

Search for similar issues before investigating from scratch:
```bash
# Search by category
grep -r "Category: Audio" docs/debug-logs/
grep -r "Category: Permissions" docs/debug-logs/

# Search by symptom or error
grep -r "permission.*denied" docs/debug-logs/
grep -r "CancellationError" docs/debug-logs/

# Search by component
grep -r "PermissionManager" docs/debug-logs/
grep -r "TranscriptionService" docs/debug-logs/
```

The debug logs capture:
- Known bugs and their fixes
- Root cause analysis
- Code changes that resolved issues
- Regression tests that prevent recurrence

### After Fixing a Bug

**Document the fix in a debug log**: Use the Cursor command or see [`.cursor/commands/create_debug_log.md`](.cursor/commands/create_debug_log.md)

1. Create a new debug log file: `docs/debug-logs/YYYY-MM-DD_description.md`
2. Fill in the template (see [`docs/debug-logs/template.md`](docs/debug-logs/template.md)):
   - Problem description
   - Symptoms/error messages
   - Root cause analysis
   - Fix description
   - Affected files
   - Code snippets (before/after)
3. Add regression test if applicable
4. Update index in [`docs/debug-logs/README.md`](docs/debug-logs/README.md)

This builds a searchable knowledge base that helps future debugging sessions.

## Git Workflow (GitHub Flow)

Simple, agent-friendly branching. All work happens in feature branches merged to `main` via PRs.

**For comprehensive workflow documentation**: See [`spec/git_workflow.md`](spec/git_workflow.md)

**Quick commands for agents**:
- Create PR: `gh pr create --fill`
- Merge PR: `gh pr merge --squash --delete-branch`
- Create release: `git tag vX.Y.Z && git push origin vX.Y.Z`
- Check status: `gh pr status`

**Branch naming**: `feature/name`, `bugfix/name`, `hotfix/name`, `refactor/name`

## Reference

**Dependencies**:
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — on-device speech-to-text
- ScreenCaptureKit — system framework for audio capture
- GitHub CLI (`gh`) — for PR management from command line

**Testing**: Use Zoom/Meet/Teams or QuickTime Player. Verify permissions, recording cycles, transcript accuracy.

**Debugging Knowledge Base**: [`docs/debug-logs/`](docs/debug-logs/) — searchable archive of past debugging sessions, root causes, and fixes. Check here before investigating complex issues.

**Reference projects**: Azayaka (menu bar + SCK), WhisperKit Sample, Apple's ScreenCaptureKit Sample
