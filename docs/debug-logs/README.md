# Debug Logs

A searchable knowledge base of debugging sessions, documenting problems, root causes, and fixes.

## Purpose

This directory captures tribal knowledge from debugging sessions to help developers (human and AI) quickly identify and fix similar issues in the future. Each debug log documents:

- What went wrong
- How it manifested (symptoms, errors)
- Why it happened (root cause)
- How it was fixed
- What code changed

## Creating a Debug Log

Use the Cursor command to quickly create a new debug log:

1. Open Cursor command palette (Cmd+Shift+P)
2. Search for "Create Debug Log"
3. Or use the command file: [`.cursor/commands/create_debug_log.md`](../../.cursor/commands/create_debug_log.md)

The command will create a new file with today's date and the template structure.

## Template

See [`template.md`](template.md) for the standard debug log format.

## Index of Debug Logs

### 2026

#### February

- [2026-02-24: AEC Convergence Failure with Non-48kHz Microphones](2026-02-24_aec_convergence_non48khz_mic.md) - Sample-time domain mismatch causes false discontinuities, permanently freezing AEC when mic resampler is active
- [2026-02-18: Mid-Session Permission Recovery](2026-02-18_mid-session-permission-recovery.md) - Permission-denied errors during recording start silently failed with no UI feedback
- [2026-02-17: Microphone Sample Rate Race Condition](2026-02-17_mic-sample-rate-race.md) - Cached micFormatDesc overwritten with wrong sample rate, causing sped-up microphone playback

#### January

- [2026-01-24: AEC Zero Match Rate Bug](2026-01-24_aec-zero-match-rate.md) - Echo cancellation shows 0% match rate despite successful stream sync (IN PROGRESS)
- [2026-01-22: CI Code Signing Workflow Bug](2026-01-22_ci-signing-workflow-bug.md) - Workflow checked undefined env vars instead of secrets
- [2026-01-15: Screen Recording Permission Detection Unreliable](2026-01-15_screen-recording-permission-detection.md) - CGPreflightScreenCaptureAccess() fails with ad-hoc signing

## Search Tips for Agents

When debugging a new issue, search this directory first:

**By component/category:**
```bash
grep -r "Category: Audio" docs/debug-logs/
grep -r "Category: Permissions" docs/debug-logs/
grep -r "Category: Transcription" docs/debug-logs/
```

**By symptom:**
```bash
grep -r "permission" docs/debug-logs/
grep -r "crash" docs/debug-logs/
grep -r "audio.*zero" docs/debug-logs/
```

**By error message:**
```bash
grep -r "CancellationError" docs/debug-logs/
grep -r "denied" docs/debug-logs/
```

**By affected file:**
```bash
grep -r "PermissionManager.swift" docs/debug-logs/
grep -r "TapAudioCaptureService.swift" docs/debug-logs/
```

## Categories

Debug logs are categorized by component:

- **Audio** - Audio capture, playback, processing
- **Permissions** - TCC permissions (screen recording, microphone)
- **Transcription** - WhisperKit, speech-to-text processing
- **UI** - SwiftUI views, window management
- **Recording** - Recording lifecycle, state management
- **File I/O** - Saving, loading, export
- **Models** - WhisperKit model download/management
- **Echo Cancellation** - AEC processing
- **LLM** - LLM-based refinement features

## Related Documentation

- **Regression Tests**: [`MuesliTests/RegressionTests.swift`](../../MuesliTests/RegressionTests.swift) - Test cases for known bugs
- **Architecture**: [`AGENTS.md`](../../AGENTS.md) - System architecture and known pitfalls
- **Spec**: [`SPEC.md`](../../SPEC.md) - Product specification

## Maintenance

### Adding New Logs

1. Use the Cursor command or copy `template.md`
2. Name file: `YYYY-MM-DD_short-description.md`
3. Fill in all template sections
4. Add entry to index above (maintain chronological order)
5. Commit to git

### Updating the Index

When adding a new debug log, update the "Index of Debug Logs" section above with:
- Date (YYYY-MM-DD)
- Short title
- One-line summary
- Link to the file

Keep entries in reverse chronological order (newest first) within each month.
