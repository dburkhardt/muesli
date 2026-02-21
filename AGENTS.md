# AGENTS.md — Muesli (macOS meeting transcription)

Meeting transcription for macOS: captures audio (Zoom/Teams/Meet) + mic, real-time transcription via WhisperKit, saves `audio.caf` + `microphone.caf` + `transcript.md`.

**Authoritative docs**: `SPEC.md` (product spec + phases) · This file (architecture + commands + pitfalls) · `.cursorrules` (working rules + phase discipline)
**Note for agents**: Additional flow-specific documentation lives in the `spec/` folder. If you are doing a comprehensive architecture review, read those documents as well.

**Code signing & notarization**: App is signed with Developer ID and notarized by Apple when released via GitHub Actions. Credentials stored in repository secrets (never committed to git).

## Quick Reference

| Aspect | Value |
|--------|-------|
| Platform | macOS 26+ |
| Language | Swift 6 |
| UI | SwiftUI with `@Observable` |
| Architecture | `MuesliViewModel` (app state) + `RecordingSession` (per-recording) |
| Audio | Core Audio Taps (macOS 14.2+) via AVAudioEngine |
| Transcription | WhisperKit |
| Package manager | Swift Package Manager |

## Working Rules

1. **Follow SPEC.md phases** — one at a time, verify checkpoint before proceeding
2. **Small diffs, compile often** — keep the app buildable at all times
3. **Work autonomously** — fix bugs, implement improvements, and complete tasks without asking permission. Only pause for: destructive actions (deleting files/data), multiple valid architectural approaches, or genuine uncertainty about user intent. Report what you did, not what you're about to do.
4. **Native patterns** — Swift 6 concurrency, `@Observable`, one type per file
5. **UI principle** — "Granola-inspired": minimal, clean, fast
6. **Track future work** — add todos to [`plans/todo.md`](plans/todo.md) or create a GitHub Issue for larger features
7. **Preserve debugging code** — do not remove print statements, Logger calls, or temporary debugging code without asking the user first

## Todo Tracking

**Location**: [`plans/todo.md`](plans/todo.md)

Track future work, features, and improvements in the todo file. Use the `/todo` Cursor command to add new entries.

**When to use todos vs GitHub Issues**:
- **Todo file**: Quick notes, implementation details, small improvements
- **GitHub Issues**: Larger features, bugs that need discussion, work that may span multiple PRs

**Todo format**:
```markdown
## [Category] - Brief Description

Detailed description of the feature or improvement.

### Requirements
- Specific requirement 1
- Specific requirement 2
```

**Agents should**:
- Check `plans/todo.md` when planning work to understand pending items
- Add new todos when discovering future work during implementation
- Remove or update todos when completing related work

## Commands

**Build & Launch** (recommended):

The build takes 1-8 minutes depending on cache state. Run the build in the background and poll until it finishes:

```bash
# 1. Start the build in background
./scripts/build-and-launch.sh
```

Run the build script in the background (using the Bash tool's `run_in_background` parameter). Then poll for completion with a while loop + sleep:

```bash
# 2. Poll until build completes (check every 15 seconds)
while [ -f /tmp/muesli-build.lock ]; do sleep 15; done

# 3. Check result
LOG=$(ls -t /tmp/muesli-build-*.log | head -1)
if grep -q "BUILD SUCCEEDED" "$LOG"; then
  echo "SUCCESS"; grep "BUILD TIMESTAMP:" "$LOG"; cat /tmp/muesli-build-timestamp.txt
else
  echo "FAILED"; grep "error:" "$LOG" | head -20
fi
```

**Build timestamp verification** (REQUIRED after build success):
- After successful build, the log includes a prominent `BUILD TIMESTAMP` box
- The timestamp is also written to `/tmp/muesli-build-timestamp.txt`
- **Agents MUST provide this timestamp to the user** when reporting build completion
- Format: UTC ISO 8601 (e.g., `2026-01-24T15:49:31Z`)
- User can verify in app: Help → About → Build Details → Built
- This ensures the user knows they're running the exact build that was just compiled

**If the build fails**, check the log for errors:

```bash
grep "error:" "$(ls -t /tmp/muesli-build-*.log | head -1)" | head -20
```

**Build & Launch options**:
```bash
./scripts/build-and-launch.sh              # Fast rebuild with cached intermediates (DEFAULT)
./scripts/build-and-launch.sh --deep-clean # Full cache clear (use if builds behave unexpectedly)
./scripts/build-and-launch.sh --build-only # Build without launching
./scripts/build-and-launch.sh --no-log     # Disable logging to file
./scripts/build-and-launch.sh --dry-run    # Show what would happen
```

**What the script does** (preserves caches for fast rebuilds by default):
- Logs all output to `/tmp/muesli-build-TIMESTAMP.log` (strips ANSI colors)
- Uses lock file `/tmp/muesli-build.lock` to prevent parallel builds
- Preserves DerivedData intermediates for incremental compilation
- Removes only app bundles to ensure fresh binary
- Runs `xcodebuild clean build` to recompile changed sources
- Build time: ~1-2 minutes (vs 5-8 min with `--deep-clean`)

**Advanced options** (rarely needed):
- `--deep-clean` — Full cache clear (DerivedData, Launch Services, module caches); use if builds behave unexpectedly
- `--incremental` — Skip xcodebuild clean (fastest, but may miss some changes)

**Other commands**:
- Test: `xcodebuild ... test 2>&1 | tee "/tmp/muesli-test-${TIMESTAMP}.txt"`
- Test with coverage: `./scripts/generate-coverage.sh`
- Clean: `xcodebuild ... clean`
- Reset permissions (onboarding testing only): `./scripts/test-onboarding.sh` or `./scripts/build-and-launch.sh --reset-tcc`
- Uninstall completely (interactive): `./scripts/uninstall.sh`
- Generate changelog: `git-cliff --latest --strip header,footer > CHANGELOG.md`
- Create DMG (modern): `./scripts/create-dmg-modern.sh [VERSION]`
- Create DMG (legacy): `./scripts/create-dmg.sh [VERSION]`

**Efficient workflows**: Save build/test output once with `| tee` to `/tmp/`, then grep the file. Never re-run to extract different info.

**TCC Permission Persistence**: With stable code signing (`DEVELOPMENT_TEAM`), TCC permissions persist across builds. You only need to grant permissions once after a fresh clone. Use `--reset-tcc` or `test-onboarding.sh` only when testing the onboarding flow.

**First Build After Clone**: 
New developers cloning the repo will need to grant Screen & System Audio Recording and Microphone permissions once when first launching the app. This is expected behavior:
1. Build and launch: `./scripts/build-and-launch.sh`
2. Grant permissions when prompted in System Settings
3. Subsequent builds will preserve these permissions (no re-granting needed)

**Per-bundle-ID permissions**: Each worktree branch with a different bundle ID has separate TCC permissions. You'll grant permissions once per worktree.

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
2. Services - TapAudioCaptureService, TranscriptionService, FileOutputService
3. Managers - ModelManager, MeetingHistoryManager, PreferencesManager
4. Coordinators - TranscriptionCoordinator, RefinementCoordinator
5. Views - Complex UI logic (lower priority than business logic)

## CI Builds (Unsigned)

CI builds (`ci.yml`) are intentionally **unsigned** for speed and fork compatibility. Code signing and notarization only happen in the **release workflow** (`release.yml`).

**Why unsigned CI?**
- CI runners have no TCC database, so signing provides no benefit for tests
- Removing signing saves ~2 minutes per CI run
- Fork PRs can run CI without access to signing secrets

**CI workflow details**:
- `test` job: Builds + runs tests with coverage (single `xcodebuild test` invocation)
- CI skips heaviest test classes (~400 tests) to keep runs under ~25 min; full suite runs locally
- Skipped in CI: MuesliViewModelTests, TranscriptionServiceTests, FileOutputServiceTests, EchoCancellationServiceTests, CoreAudioTapTests, ModelManagerTests
- Run full suite locally: `xcodebuild -project Muesli.xcodeproj -scheme Muesli test`
- `lint` job: Runs SwiftLint (no build required)
- `build-release` job: Verifies Release configuration compiles (unsigned)
- All jobs have timeout guards (30 min for build jobs, 10 min for lint)
- Concurrency controls auto-cancel stale runs on the same branch

**Release workflow** (`release.yml`): Signs with Developer ID and notarizes via Apple. This is the only workflow that uses signing secrets.

**Monitoring CI/Release workflows**: After pushing code or tags that trigger workflows, poll for completion using `watch-release.sh` or `gh run watch`:

```bash
# Watch the most recent CI run (poll with while loop + sleep)
RUN_ID=$(gh run list --limit 1 --json databaseId -q '.[0].databaseId')
while true; do
  STATUS=$(gh run view "$RUN_ID" --json status -q '.status')
  [ "$STATUS" != "in_progress" ] && [ "$STATUS" != "queued" ] && break
  sleep 15
done
CONCLUSION=$(gh run view "$RUN_ID" --json conclusion -q '.conclusion')
echo "Run $RUN_ID: $CONCLUSION"

# Or for release builds specifically:
./scripts/watch-release.sh
```

Run the monitoring command in the background (using the Bash tool's `run_in_background` parameter) and check results when it completes. Do NOT wait for the user to report CI results — poll and report them yourself.

## Versioning (CRITICAL FOR AGENTS)

**Golden Rule**: `Version.xcconfig` MUST be updated and committed BEFORE creating any git tag. The CI workflow's `sed` of Version.xcconfig during builds is transient (not committed back), so if Version.xcconfig doesn't match the tag, the committed version will be wrong.

### Version Bump Procedure

Always follow this exact sequence:

```bash
# 1. Edit Version.xcconfig
#    Change MARKETING_VERSION = X.Y.Z

# 2. Verify the change
grep MARKETING_VERSION Version.xcconfig

# 3. Commit
git add Version.xcconfig
git commit -m "chore: Bump version to X.Y.Z"

# 4. Create tag (must start with 'v')
git tag vX.Y.Z

# 5. Push both commit and tag
git push origin <branch>
git push origin vX.Y.Z
```

### RC Workflow (from feature branches)

Use release candidates to test builds before merging to main:

```bash
# 1. Ensure Version.xcconfig is already set to the target version (e.g., 0.6.0)
grep MARKETING_VERSION Version.xcconfig  # Should show 0.6.0

# 2. Tag the RC
git tag v0.6.0-rc.1

# 3. Push the tag (triggers release workflow, creates pre-release)
git push origin v0.6.0-rc.1

# 4. If issues found, fix on branch, then:
git tag v0.6.0-rc.2
git push origin v0.6.0-rc.2
```

### Stable Release Workflow (from main)

After the PR is merged to main:

```bash
# 1. Verify Version.xcconfig on main has the correct version
git checkout main && git pull
grep MARKETING_VERSION Version.xcconfig

# 2. Tag the stable release
git tag v0.6.0
git push origin v0.6.0

# 3. Watch the release build
./scripts/watch-release.sh
```

### Common Agent Scenarios

**"Bump a patch version"**:
```bash
# Check current version
grep MARKETING_VERSION Version.xcconfig  # e.g., 0.5.2
# Edit to 0.5.3, commit, tag, push (follow procedure above)
```

**"Create an RC from this branch"**:
```bash
# Verify Version.xcconfig matches intended version
grep MARKETING_VERSION Version.xcconfig
# If not, bump it first (commit before tagging!)
git tag vX.Y.Z-rc.N
git push origin vX.Y.Z-rc.N
```

**"Release this"** (from main):
```bash
grep MARKETING_VERSION Version.xcconfig  # Verify version
git tag vX.Y.Z && git push origin vX.Y.Z
./scripts/watch-release.sh
```

### Troubleshooting: Version Mismatch

If a tag was created without updating Version.xcconfig:
1. Delete the tag: `git tag -d vX.Y.Z && git push origin :refs/tags/vX.Y.Z`
2. Delete the release: `gh release delete vX.Y.Z --yes`
3. Update Version.xcconfig, commit, re-tag, push

## Release Process

### Creating a Release

Follow the [Versioning](#versioning-critical-for-agents) section above for the exact procedure. In summary:

1. Update `Version.xcconfig` and commit
2. Create and push tag: `git tag vX.Y.Z && git push origin vX.Y.Z`
3. Monitor with `./scripts/watch-release.sh`
4. Verify: check GitHub Releases, download DMG, test installation

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
- [ ] Different Whisper models (small, medium, large-v3, large-v3-turbo)
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

## Architecture

### App Structure
- `MuesliApp` — MenuBarExtra + single main Window
- **Single-window model**: Shows `UnifiedHistoryView` (idle) or split view (recording/viewing)
- **Contextual sizing**: compact for list, adjusts for split view

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
System Audio: Core Audio Tap → TapCaptureRing → AudioWorker → AECProcessor
                                                               ├── FileOutputService (audio.caf)
                                                               └── TranscriptionService (→16kHz→WhisperKit)
Microphone:   AVAudioEngine → MicCaptureRing → AudioSynchronizer → AECProcessor → ...
```

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
- `CGPreflightScreenCaptureAccess()` — Secondary guard only with stable signing. System audio permission is determined by tap-probe at session start; the result is cached in UserDefaults.
- `PermissionManager.checkScreenRecordingPermissionAsync()` — Uses tap-probe + UserDefaults for authoritative check. Includes 5-minute caching to reduce prompt frequency.
- Do NOT use `SCShareableContent` for meeting app detection (triggers prompt). Use `NSWorkspace.shared.runningApplications` instead.

**If TCC Permissions Reset Unexpectedly**:
1. Verify stable signing: `codesign -d -r- ./DerivedData/.../Muesli.app | grep "subject.OU"`
2. Check DEVELOPMENT_TEAM in project.pbxproj: `grep DEVELOPMENT_TEAM Muesli.xcodeproj/project.pbxproj`
3. Temporary workaround: Use `--reset-tcc` on every build until signing is fixed
4. See [plans/code_signing.md](plans/code_signing.md) for full troubleshooting guide

### Audio Sample Rates (CRITICAL)
**If transcription outputs gibberish, check sample rates first!** WhisperKit requires 16kHz. Both system audio (Core Audio tap) and microphone (AVAudioEngine) capture at 48kHz. Use `TranscriptionService.resampleToWhisperFormat()`:
```swift
// System: 48kHz stereo → 16kHz mono
resampleToWhisperFormat(buffer, sourceSampleRate: 48000, sourceChannels: 2)
// Mic: 48kHz mono → 16kHz mono
resampleToWhisperFormat(buffer, sourceSampleRate: 48000, sourceChannels: 1)
```

### Core Audio Taps
- `AudioHardwareCreateProcessTap` requires macOS 14.2+
- IOProc constraints: no heap allocation, no Objective-C, no locks in the audio callback
- Aggregate device setup required for combining system + mic audio
- Use lock-free ring buffers for audio handoff from IOProc to Swift

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
- Create release: Update `Version.xcconfig` first, commit, then `git tag vX.Y.Z && git push origin vX.Y.Z` (see [Versioning](#versioning-critical-for-agents))
- Check status: `gh pr status`

**Branch naming**: `feature/name`, `bugfix/name`, `hotfix/name`, `refactor/name`

## Best Practices

- **System audio permission model**: Use tap-probe at session start to determine permission status; do not rely on `CGPreflightScreenCaptureAccess()` as a preflight. Cache the tap-probe result in UserDefaults.
- **RT audio callback constraints**: No heap allocation, no Objective-C, no locks in the IOProc callback. Use lock-free ring buffers for all audio handoff from the real-time thread to Swift.
- **WhisperKit sample rate**: WhisperKit requires 16 kHz mono audio. Always resample from the 48 kHz capture rate using `TranscriptionService.resampleToWhisperFormat()`.
- **macOS version requirement**: `AudioHardwareCreateProcessTap` requires macOS 14.2+. The app's deployment target is macOS 26.0.

## Reference

**Dependencies**:
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — on-device speech-to-text
- [MLXLLM / MLXLMCommon](https://github.com/ml-explore/mlx-swift-examples) — on-device LLM transcript refinement
- Core Audio / AVAudioEngine — system audio capture via process taps
- GitHub CLI (`gh`) — for PR management from command line

**Testing**: Use Zoom/Meet/Teams or QuickTime Player. Verify permissions, recording cycles, transcript accuracy.

**Debugging Knowledge Base**: [`docs/debug-logs/`](docs/debug-logs/) — searchable archive of past debugging sessions, root causes, and fixes. Check here before investigating complex issues.

**Reference projects**: Azayaka (menu bar + SCK), WhisperKit Sample, Apple's ScreenCaptureKit Sample
