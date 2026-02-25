# Consolidated Automatic Finalization Workflow Migration

**Date**: 2026-02-24 23:10
**Category**: Transcription

## Problem Description

Preferences exposed two overlapping automatic post-meeting workflows:

- `Finalize transcript after recording` (second-pass ASR)
- `Reprocess after every meeting` (auto-reprocess)

This overlap made behavior hard to predict and increased risk of duplicate post-stop paths.

## Symptoms/Error Messages

- Users saw two different toggles that appeared to do similar work.
- Model selection options for automatic finalization were overly complex (`bestAvailableNoDowngrade`, `specific`) for common use.
- Legacy settings could create ambiguous behavior after upgrades.

## Root Cause Analysis

- Automatic finalization and automatic reprocess were configured independently.
- Legacy model preference enum included modes that were no longer needed for the desired UX.
- Migration rules for older settings combinations were not explicit.
- `sameAsLive` resolution could be incorrect when live transcription used a fallback model during session startup.

## Fix Description

- Consolidated to one automatic workflow controlled by `secondPassASREnabled`.
- Reduced automatic model preference to two options:
  - `sameAsLive`
  - `bestAvailable`
- Added one-time, idempotent migration:
  - unified toggle = `legacySecondPassEnabled OR legacyAutoReprocessEnabled`
  - legacy model mappings:
    - `bestAvailableNoDowngrade` -> `bestAvailable`
    - `specific` -> `sameAsLive`
  - removed legacy keys after migration:
    - `autoReprocessAfterMeetingEnabled`
    - `secondPassSpecificModel`
- Kept short-recording minimum-duration guard for automatic finalization.
- Kept empty-transcript rescue path via `onAutoReprocessRequested`.
- Tracked effective live model per recording session and passed it to second-pass finalization to keep `sameAsLive` semantically correct under fallback.

## Affected Files

- `Muesli/Managers/PreferencesManager.swift`
- `Muesli/Utilities/AppStorageKeys.swift`
- `Muesli/Views/PreferencesView.swift`
- `Muesli/Controllers/RecordingController.swift`
- `Muesli/Managers/TranscriptionCoordinator.swift`
- `Muesli/Models/RecordingSession.swift`
- `MuesliTests/PreferencesManagerTests.swift`
- `MuesliTests/TranscriptionCoordinatorTests.swift`
- `MuesliTests/RecordingControllerTests.swift`
- `MuesliTests/RegressionTests.swift`
- `spec/model_compilation_detection.md`

## Prevention/Testing

- Added migration matrix tests, stale-value mapping tests, cleanup checks, and idempotency coverage.
- Added fallback-model tracking tests for `effectiveLiveModelForSession`.
- Added regression assertions for unified stop-flow gate and empty-transcript rescue conditions.

## Notes

- Manual reprocess context menus remain unchanged and still allow direct per-model selection.
- Automatic finalization model picker now uses dependent disclosure in Preferences (shown only when finalization is enabled).
