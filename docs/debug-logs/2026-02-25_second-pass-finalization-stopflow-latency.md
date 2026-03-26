# Second-Pass Finalization Stop-Flow Latency and Session Lifetime Race

**Date**: 2026-02-25 15:10
**Category**: Recording

## Problem Description

Stopping a recording with second-pass ASR enabled could present as:
- No visible reprocessing indicator right after stop
- A short UI hang during stop completion
- Apparent "never finishes" behavior in some runs

The reported case was tied to meeting creation around 2026-02-25 14:39 local time and commit `163c4c8`.

## Symptoms/Error Messages

- User-visible behavior:
  - Stop action looked stalled for a couple seconds
  - Reprocessing indicator did not appear reliably
  - Transcript appeared not to complete in some sessions
- Diagnostic evidence for the 14:39 session showed backend second-pass did run and complete:

```text
[2026-02-25 14:40:24.172] [STABILIZER] secondPass:scheduled dir=2026-02-25_14-39_E1847940-4CCC-4AF2-81C0-4D58A97FD199
[2026-02-25 14:40:24.180] [STABILIZER] secondPass:start model=large-v3-v20240930_turbo
[2026-02-25 14:40:36.340] [STABILIZER] secondPass:done model=large-v3-v20240930_turbo blocks=6 segments=25 duration=12.08s
```

## Root Cause Analysis

Two logic issues overlapped:

1. Stop-flow latency from eager export:
- `runAutomaticFinalizationIfEligible` always awaited export before returning, even when second-pass had already been launched.
- Export runs file-system work on `@MainActor` paths, so stop completion could feel blocked.

2. Session-lifetime race in second-pass task startup:
- `launchSecondPassFinalization` required both `self` and `session` at task start.
- If `RecordingSession` deallocated before task execution, the task exited before `runSecondPassASR`.
- That could skip transcript rewrite work and make behavior appear incomplete/intermittent.

## Fix Description

- Deferred immediate export when second-pass is launched:
  - Keep export in the second-pass completion path (`launchSecondPassFinalization`) instead.
  - This keeps stop completion responsive and avoids duplicate/early export work.
- Removed hard dependency on strong `session` at task start:
  - Snapshot `liveModelAtStop` before spawning task.
  - Require only `self` to run second-pass ASR.
  - Gate UI transcript replay on `session` availability, but allow second-pass file finalization to complete even if the live session object is gone.

## Affected Files

- `Muesli/Controllers/RecordingController.swift` - Deferred export in second-pass path and removed task startup race on weak `session`.

## Code Snippets

### Before

```swift
if decision.shouldLaunchSecondPass {
    launchSecondPassFinalization(for: session, directory: directory)
    automaticFinalizationLaunched = true
}

await exportMeetingIfEnabled(directory: directory)

secondPassFinalizationTask = Task { [weak self, weak session, transcriptionCoordinator] in
    guard let self, let session else { return }
    let blocks = try await self.transcriptionCoordinator.runSecondPassASR(
        in: directory,
        recordingStartTime: meetingDate,
        preference: self.preferencesManager.secondPassModelPreference,
        liveModel: session.effectiveLiveModel
    )
    ...
}
```

### After

```swift
if decision.shouldLaunchSecondPass {
    session.effectiveLiveModel = transcriptionCoordinator.effectiveLiveModelForSession ?? session.effectiveLiveModel
    launchSecondPassFinalization(for: session, directory: directory)
    automaticFinalizationLaunched = true
}

if !automaticFinalizationLaunched {
    await exportMeetingIfEnabled(directory: directory)
}

let liveModelAtStop = session.effectiveLiveModel
secondPassFinalizationTask = Task { [weak self, weak session, transcriptionCoordinator, liveModelAtStop] in
    guard let self else { return }
    let blocks = try await self.transcriptionCoordinator.runSecondPassASR(
        in: directory,
        recordingStartTime: meetingDate,
        preference: self.preferencesManager.secondPassModelPreference,
        liveModel: liveModelAtStop
    )
    await MainActor.run {
        guard let session else { return }
        ...
    }
}
```

## Prevention/Testing

- Targeted tests passed:
  - `RecordingControllerTests`
  - `TranscriptionCoordinatorTests`
- Existing processing-state tests continue to cover second-pass activation/clearing behavior.
- Follow-up recommendation: add a dedicated regression test asserting stop callback timing parity when second-pass + export are both enabled.

## Related Issues/PRs

- Related debug log: `2026-02-25_reprocessing-ui-stuck-stale-selection.md`
- Related debug log: `2026-02-24_reprocessing-race-condition.md`

## Notes

- For the specific 14:39 recording, logs confirm second-pass completed at 14:40:36.
- The fix targets the intermittent stop UX and race path that can make completion appear unreliable.
