# PR #17 Handoff — feat(transcription): chunk size 15s + context chaining

**Date**: 2026-02-22
**PR**: https://github.com/dburkhardt/muesli/pull/17
**Branch**: `feature/chunk-size-context-chaining`
**Status**: CI running — 1 known test failure remaining (easy fix below)

---

## What was done this session

### 1. Rebased onto current main
The PR branch had accumulated commits from main (including #18, #24) mixed in. Cleaned up by cherry-picking only the two PR-specific commits onto fresh `origin/main`:
- `f392ba7` — `feat(transcription): increase chunk size to 15s with warmup and add context chaining`
- `ac6974d` — `fix(transcription): address review findings for chunk size + context chaining`

The `77fdae2` CI commit (skip EchoCancellationServiceNLMSTests) was **dropped** because main's new CI already handles it via `testConcurrentAccess`-only skip.

### 2. Resolved merge conflicts
Two files conflicted because main's PR #24 ran `swiftlint --fix` and restructured the same code the PR touches:

**`Muesli/Services/TranscriptionService.swift`** — `processRemainingAudio()` conflict:
- Main refactored the 5-tuple into a `RemainingAudio` struct
- PR added `sysContext`/`micContext` fields and `previousText:` to `transcribeChunk` calls
- Resolution: kept the struct pattern (lint-compliant) **and** added the two context fields

**`Muesli/Views/PreferencesView.swift`** — Slider description text:
- Main reformatted the string to fit line-length limits
- PR updated the copy to mention "15-30s" and Whisper context
- Resolution: took PR's copy but wrapped to fit `<150` chars

### 3. Lint (informational — non-blocking)
Main's new CI marks the SwiftLint job `continue-on-error: true` — lint failures are advisory only and will **not** block merge. The structural violations (file_length, type_body_length, function_body_length) are pre-existing in both main and this PR; no new violations were introduced.

---

## Remaining failure (1 test)

**Test**: `RegressionTests.testTranscriptionTimingValues`
**Location**: `MuesliTests/RegressionTests.swift:290`
**CI run**: https://github.com/dburkhardt/muesli/actions/runs/22283724244

**Failure**:
```
XCTAssertEqual failed: ("15.0") is not equal to ("5.0")   ← chunkDuration
XCTAssertEqual failed: ("3.0") is not equal to ("1.5")    ← overlapDuration
XCTAssertEqual failed: ("240000") is not equal to ("80000") ← minSamples
XCTAssertEqual failed: ("48000") is not equal to ("24000")  ← overlapSamples
```

**Root cause**: This regression test was written to lock in the old 5s defaults. The PR intentionally changed those defaults to 15s.

**Fix** (2-line change in `MuesliTests/RegressionTests.swift`):
```swift
// MuesliTests/RegressionTests.swift:291-296 — update to new defaults
func testTranscriptionTimingValues() async {
    XCTAssertEqual(AudioConfiguration.transcriptionChunkDuration, 15.0)  // was 5.0
    XCTAssertEqual(AudioConfiguration.transcriptionOverlapDuration, 3.0)  // was 1.5

    // Derived values
    XCTAssertEqual(AudioConfiguration.minSamplesForProcessing, 240_000)  // 16000 * 15
    XCTAssertEqual(AudioConfiguration.overlapSamples, 48_000)            // 16000 * 3
}
```

Also update the inline comments (`// 16000 * 5` → `// 16000 * 15`, `// 16000 * 1.5` → `// 16000 * 3`).

After this fix, push and CI should go green on `Test Required Stable`.

---

## What the PR does (context for reviewers)

- **Chunk size**: `5s → 15s` default (configurable 2–30s via Preferences). Whisper was trained on 30s windows; 5s chunks caused word-boundary errors and context loss.
- **Warmup**: First chunk per speaker uses a shorter 5s window to reduce time-to-first-text.
- **Context chaining**: Last ~200 chars of each speaker's transcript passed as `promptTokens` to WhisperKit for the next chunk — improves capitalization, proper nouns, cross-boundary continuity.
- **Fallback**: If `promptTokens` causes false no-speech (WhisperKit #372), retry without context.
- **Threshold tuning**: `logProbThreshold` relaxed to -1.0, `firstTokenLogProbThreshold` set to -1.5 to prevent prompt-induced rejection.

---

## Key files changed by the PR

| File | What changed |
|------|-------------|
| `Muesli/Services/TranscriptionService.swift` | Context chaining, warmup logic, new `transcribeChunk` signature with `previousText:` |
| `Muesli/Utilities/AudioConfiguration.swift` | `transcriptionChunkDuration` 5→15, overlap 1.5→3 |
| `Muesli/Utilities/AppStorageKeys.swift` | Added `audioChunkDuration` key |
| `Muesli/Managers/PreferencesManager.swift` | `audioChunkDuration` preference (2–30s range), `audioChunkDurationDidChange` callback |
| `Muesli/Views/PreferencesView.swift` | Slider for chunk duration (now up to 30s) |
| `MuesliTests/TranscriptionServiceTests.swift` | Tests for warmup, context chaining, retry fallback |
| `MuesliTests/PreferencesManagerTests.swift` | Tests for new chunk duration preference |
| `MuesliTests/PolishFeaturesTests.swift` | Integration-style polish tests |

---

## Local branch state

- **Local branch**: `feature/chunk-size-context-chaining-rebased` (same content as remote, kept as backup)
- **Remote**: `origin/feature/chunk-size-context-chaining` — force-pushed with clean rebase
- **Local `feature/chunk-size-context-chaining`**: points at old pre-rebase tip (`36dd040`) — can be updated with `git reset --hard origin/feature/chunk-size-context-chaining`
