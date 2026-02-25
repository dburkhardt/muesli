# Reprocessing Indicator Stuck Due to Stale Selected Meeting Reference

**Date**: 2026-02-25 12:40
**Category**: UI

## Problem Description

A completed meeting could remain in "Reprocessing…" in the detail pane long after automatic second-pass ASR finished.

## Symptoms/Error Messages

- User-visible behavior: detail pane processing indicator remained active for multiple minutes on a short (~30s) recording.
- Runtime logs showed second-pass completed quickly for the same meeting.
- `transcript.md` was written successfully with finalized content.

```
[STABILIZER] secondPass:scheduled dir=...
[STABILIZER] secondPass:start model=...
[STABILIZER] secondPass:done model=... duration=7.24s
```

## Root Cause Analysis

`MuesliViewModel` marks the newly selected meeting instance as `isReprocessing = true` when second-pass starts.  
When second-pass ends, `RecordingController` triggers a history refresh. That refresh replaces `meetingHistory` objects with newly discovered instances from disk, but `selectedMeeting` was not reconciled to the refreshed instance.

Result:
- UI continued observing the stale `selectedMeeting` object (with `isReprocessing = true`)
- New instance in refreshed history did not carry that transient state
- Indicator appeared "stuck" despite completed second-pass

## Fix Description

- Added selection reconciliation in `MeetingHistoryManager.loadMeetingHistory()`:
  - Preserve previous selected meeting id/directory and selection IDs.
  - Rebind `selectedMeeting` to refreshed meeting instances by ID (fallback directory).
  - Prune stale IDs from `selectedMeetingIDs`.
- Switched manager dependency to `MeetingHistoryServiceProtocol` and used protocol transcript-loading methods to keep tests injectable.
- Added regression tests covering rebind and stale-ID pruning.

## Affected Files

- `Muesli/Managers/MeetingHistoryManager.swift` - Reconcile selection after refresh and prune stale selected IDs
- `MuesliTests/MuesliViewModelTests.swift` - Added regression coverage for selection rebind/pruning behavior

## Code Snippets

### Before

```swift
func loadMeetingHistory() {
    meetingHistory = meetingHistoryService.discoverMeetings()
    groupedHistory = groupMeetingsByDate(meetingHistory)
}
```

### After

```swift
func loadMeetingHistory() {
    let previousSelectedMeetingID = selectedMeeting?.id
    let previousSelectedDirectory = selectedMeeting?.directory.standardizedFileURL
    let previousSelectedMeetingIDs = selectedMeetingIDs

    meetingHistory = meetingHistoryService.discoverMeetings()
    reconcileSelectionAfterReload(
        previousSelectedMeetingID: previousSelectedMeetingID,
        previousSelectedDirectory: previousSelectedDirectory,
        previousSelectedMeetingIDs: previousSelectedMeetingIDs
    )
    groupedHistory = groupMeetingsByDate(meetingHistory)
}
```

## Prevention/Testing

- Added regression tests:
  - `testMeetingHistoryManagerRefreshRebindsSelectedMeetingInstance`
  - `testMeetingHistoryManagerRefreshPrunesStaleSelectionIDs`
- Verified with targeted suite run:
  - `xcodebuild ... -only-testing:MuesliTests/MuesliViewModelTests test`
  - Result: test suite passed.

## Related Issues/PRs

- Related debug log: `2026-02-24_reprocessing-race-condition.md`
- Related debug log: `2026-02-25_asr-finalization-interruption-gap.md`

## Notes

- This issue was a UI state/reference problem, not a slow ASR execution problem.
- For the reported meeting, logs confirmed second-pass completion in ~7 seconds and successful transcript write.
