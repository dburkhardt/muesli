# AEC Regression Bugfix Plan (2026-01-25)

**Version**: 2 (Updated based on 7 peer reviews)

## Symptoms Reported

1. **No transcript during meeting** - Transcription not functioning
2. **Recording doesn't stop** - Takes >1 minute after clicking X
3. **Garbled audio files** - Output is corrupted/unusable

## Observations from Logs

### Timeline of Events

| Time | Event | Significance |
|------|-------|--------------|
| 08:56:53.883 | `OFFSET_VALIDATION: mismatch=24127 samples, correcting offset from -22207 to 1920` | Offset validation triggered (new code) |
| 08:56:53.896 | `SYNC_OFFSET: delivery_offset=-22207 samples` | Logging bug - shows old value |
| 08:56:53.907 | `SYNC_STATE: totalSys=54720, totalMic=52800, bufferCount=57` | Normal warmup |
| 08:56:55.658 | `SYS_GAP_LARGE: 84910 samples clamped to 500ms` | **First gap - only 2s after sync!** |
| 08:57:18.170 | `SYS: delta=23.485s` | SCK timestamp 23s behind wall-clock |
| 08:57:53.485 | `DRIFT_WARNING: 66.97% drift after 61s` | Only 33% of expected samples |
| 08:58:20.009 | `SYS: delta=35.424s` | Delta growing - 35s behind |
| 08:58:32.870 | `MIC_GAP_DETECTED: -4725 samples` | Burst of rapid arrivals (negative gap) |
| 08:58:33.271 | `SYS: delta=0.056s` | **Suddenly normal!** |
| 08:58:35.682 | `MATCH: 56/100 (56.0%)` | AEC working briefly |
| 08:58:41.603 | `AEC_RECORDING_END: gaps=56, total=28000ms` | 28 seconds of gaps |

### Key Metrics

- **182 gap events** logged total
- **Gaps of ~80,000 samples** (1.67 seconds at 48kHz) occurring every ~2 seconds
- **Both system and mic streams affected** - not AEC-specific
- **Pattern**: Audio arrives in bursts with long gaps, then briefly normalizes

### The Smoking Gun

```
[08:57:18.170] SYS: sck=83988.918s, wall=84012.403s, delta=23.485s
[08:58:20.009] SYS: sck=84038.818s, wall=84074.242s, delta=35.424s
[08:58:33.271] SYS: sck=84087.458s, wall=84087.514s, delta=0.056s
```

The ScreenCaptureKit timestamp fell 35 seconds behind wall-clock time, then **suddenly caught up**. This indicates audio callbacks were being blocked/starved, then released in a burst.

---

## Analysis

### What Changed (My Commits)

1. **Offset Validation** (runs once after warmup)
   - Simple math comparing sample counts
   - Async logging via Task **⚠️ INSIDE LOCK - BUG**

2. **Bounds Check Fallback** (runs per mic buffer)
   - Simple comparison: `if targetSysIndex > totalSystemSamples`
   - Increments counter, occasional logging

3. **Periodic OFFSET_CHECK** (runs every 60 seconds)
   - Simple math, async logging

4. **Configuration Change** in MuesliViewModel:
   ```swift
   // Before
   maxDelayMs: 100  // Buffer: ~53KB
   
   // After  
   maxDelayMs: 3000  // Buffer: ~612KB (12x larger!)
   ```

### Why These Shouldn't Cause the Issue

| Change | Impact | Assessment |
|--------|--------|------------|
| Offset validation | Runs once | Negligible |
| Bounds check | Per buffer, trivial ops | Negligible |
| Periodic check | Once per 60s | Negligible |
| Larger buffer | One-time allocation | **Needs verification** |

### Yet Both Streams Are Affected

The fact that **both** system audio and microphone show identical gap patterns suggests the problem is NOT in AEC processing, but in:
1. Something common to both audio paths
2. Thread/lock contention affecting callbacks
3. System resource starvation

---

## Hypotheses

### Hypothesis 1: Lock Contention (LOW-MEDIUM confidence)

**Theory**: The OSAllocatedUnfairLock in EchoCancellationService is being held too long, starving audio callbacks.

**Evidence Against**: 
- Lock operations are simple (no I/O, no heavy computation)
- OSAllocatedUnfairLock is designed for this use case
- If lock contention were the issue, ONE stream would starve while the other proceeds (not both)

**Evidence For**:
- Task creation inside locks involves scheduler interaction (see CRITICAL BUG below)

**Test**: Add timing instrumentation inside lock, log if >0.5ms

### Hypothesis 2: Task Spawning in Audio Callbacks (HIGH confidence) ⚠️ CRITICAL BUG

**Theory**: Creating `Task { await DiagnosticLogger.shared.log() }` inside the lock creates scheduler contention.

**THIS IS A DEFINITE BUG regardless of whether it's the root cause**:
- Audio callbacks run on real-time priority threads
- Task creation involves scheduler interaction (not real-time safe)
- Can block if Task executor is saturated
- Violates audio programming best practices

**Required Action**: Move ALL Task creation outside locks immediately.

### Hypothesis 3: Larger Buffer Allocation Side Effect (MEDIUM confidence)

**Theory**: The 612KB circular buffer allocation affects cache/memory performance.

**Evidence For**:
- 612KB exceeds typical L1 cache (128KB per core on M-series)
- May cause cache thrashing during high-frequency access
- 12x increase is significant

**Evidence Against**:
- Allocation is one-time at init
- Buffer is contiguous

**Test**: Revert maxDelayMs to 100 (2-line change, <10 minutes to test)

### Hypothesis 4: External Factor / System State (MEDIUM-HIGH confidence)

**Theory**: Running 30 unit tests + build left the system in a degraded state (audio daemon, memory pressure, etc.)

**Evidence For**:
- The pattern (gaps then burst then normal) suggests system recovery
- Both streams affected identically
- SCK timestamp caught up suddenly at 08:58:33

**Test**: Restart the Mac and try again without running tests first

### Hypothesis 5: Gap Fill Feedback Loop (HIGH confidence) ⭐

**Theory**: The gap detection/fill mechanism itself is causing the slowdown:
1. Small initial delay in callback
2. Gap detected, silence buffer created and appended
3. Buffer management takes time (Array allocation ~320KB per 80,000 sample gap)
4. Next callback further delayed
5. Bigger gap detected
6. More buffer operations
7. Feedback loop until system saturates

**Evidence For**:
- Gaps started IMMEDIATELY after sync (2 seconds)
- Gaps are consistent size (~80,000 samples)
- System recovered briefly at end (08:58:33)
- 182 gap events × ~320KB = ~58MB of allocations in 28 seconds

**Evidence Against**:
- Gap fill code existed before my changes
- But my changes might have triggered it differently

---

## Investigation for All Three Symptoms

### Symptom 1: No Transcript
- **Likely cause**: Audio callback starvation → no usable audio → WhisperKit can't transcribe
- **Investigation**: Covered by hypotheses above

### Symptom 2: Recording Doesn't Stop (>1 minute)
- **Possible causes**:
  - Blocking operation or deadlock during shutdown
  - AEC service cleanup blocks on pending Tasks
  - Lock held during async operations
- **Investigation**:
  - Add timing around `RecordingController.stopRecording()`
  - Check for blocking awaits during stop
  - Verify AEC `reset()` doesn't block

### Symptom 3: Garbled Audio Files
- **Possible causes**:
  - Buffer corruption from timing issues
  - Race conditions in buffer handoff
  - Sample count mismatch from gap fill drift
- **Investigation**:
  - Verify buffer integrity in FileOutputService
  - Check CAF file headers for format consistency
  - Examine raw waveform for discontinuities

---

## Investigation Order (REVISED based on reviews)

### Step 0: Quick Tests First (Zero Code Changes)

1. **Clean System Reboot Test** (10 minutes)
   ```bash
   # 1. Restart Mac
   # 2. Launch Muesli WITHOUT running unit tests first
   # 3. Start recording immediately
   # 4. Check if regression occurs
   ```
   If issue doesn't occur → Root cause is test-suite-induced system state, not code.

2. **Check System Logs** (5 minutes)
   ```bash
   # Check for coreaudiod issues around incident time
   log show --predicate 'process == "coreaudiod"' --start '2026-01-25 08:56:00' --end '2026-01-25 08:59:00'
   
   # Check for power management events
   pmset -g log | grep -A 5 -B 5 "08:5[6-8]"
   ```

### Step 1: Quick Code Tests (Minimal Changes)

1. **Revert maxDelayMs to 100** (10 minutes)
   - 2-line change in `MuesliViewModel.swift`
   - Test if issue reproduces
   - This is fast and isolates the buffer size variable

2. **Move Task spawning outside locks** (30 minutes)
   - This is a CORRECTNESS fix, not just optimization
   - Must be done regardless of whether it's the root cause
   - See "Required Fix #1" below

### Step 2: Diagnostic Tests (If Still Needed)

3. **Disable Gap Fill** (`#if DEBUG` only)
   - If issue stops → Gap fill is involved
   - If issue persists → Look elsewhere

4. **Add Timing Instrumentation**
   - Only if Steps 0-3 don't identify the issue
   - Use throttled/sampled logging (not per-buffer)

---

## Required Fixes (Must Implement)

### Required Fix #1: Move Task Spawning Outside Locks

**This is a correctness bug that MUST be fixed regardless of root cause.**

```swift
// WRONG - Task creation inside lock, violates real-time safety
state.withLock { state in
    if condition {
        let msg = "..."  // String construction
        Task { await DiagnosticLogger.shared.log(.aec, msg) }  // ❌ BUG
    }
}

// CORRECT - Capture values inside, Task outside
var shouldLog = false
var logMsg = ""
state.withLock { state in
    if condition {
        shouldLog = true
        logMsg = "..."  // String construction can be inside if fast
    }
}
if shouldLog {
    Task { await DiagnosticLogger.shared.log(.aec, logMsg) }  // ✅ OK
}
```

### Required Fix #2: Gap Fill Toggle (DEBUG-only)

```swift
// In AudioConfiguration.swift
#if DEBUG
/// Enable/disable gap fill for diagnostic testing.
/// WARNING: Disabling causes sample count drift. Never ship disabled.
static var enableGapFill: Bool = true
#endif
```

**Risks of disabling gap fill** (per `spec/AEC_architecture.md`):
- Will cause sample count drift (expected)
- May trigger DRIFT_WARNING logs (acceptable for diagnostic)
- Audio files may have discontinuities (acceptable for testing)
- **DO NOT SHIP with gap fill disabled**

---

## Instrumentation Guidelines

**Problem**: Per-buffer `Task` logging can worsen the issue we're trying to debug.

**Solution**: Use throttled/sampled logging:

```swift
// Instead of logging every buffer:
// Task { await DiagnosticLogger.shared.log(.aec, "SYS_CALLBACK") }  // ❌

// Log summary every N buffers:
state.callbackCounter += 1
if state.callbackCounter % 100 == 0 {  // Every ~2 seconds at 48kHz
    let summary = "CALLBACK_SUMMARY: count=\(state.callbackCounter), maxLockTime=\(state.maxLockHoldTime)ms"
    Task { await DiagnosticLogger.shared.log(.aec, summary) }
    state.maxLockHoldTime = 0  // Reset for next window
}
```

---

## Success Criteria

### Phase 0 (Clean Reboot Test)
- Recording works normally after fresh system restart
- OR: Issue reproduces even after clean restart (confirms code-related)

### Phase 1 (Quick Code Tests)
- After reverting `maxDelayMs` to 100: No regression in AEC match rate
- After moving Tasks outside locks: Lock hold time <0.5ms for 99% of operations

### Phase 2 (Full Fix Validation)
- Match rate >95% after 2-second warmup
- Gap events <10 per 60 seconds of recording
- Recording stop completes within 2 seconds
- No SCK delta >2 seconds in logs
- Transcription outputs valid text
- Audio files play correctly (not garbled)

---

## Rollback Criteria

If instrumentation causes:
- Match rate to drop below 80%
- Additional gap events (>10% increase)
- Lock hold time to exceed 5ms median

Then immediately:
1. Revert instrumentation changes
2. Try clean system reboot
3. Consider full revert to last known-good commit

---

## Baseline Measurements (Before Fix)

Measure these on a WORKING build (before regression) to validate fix doesn't degrade normal case:

1. Lock hold time distribution (min/median/95th/max)
2. Gap fill frequency in normal recording
3. Callback delivery timing (system vs mic)
4. Memory allocation rate during recording

---

## Files to Modify

| File | Change | Priority |
|------|--------|----------|
| `EchoCancellationService.swift` | Move Task spawning outside locks | **REQUIRED** |
| `MuesliViewModel.swift` | Revert maxDelayMs to 100 (test) | Step 1 |
| `AudioConfiguration.swift` | Add `enableGapFill` toggle (DEBUG-only) | Step 2 |

---

## Test Coverage Updates

After fixing, add these tests to prevent regression:

```swift
// In EchoCancellationServiceTests.swift
func testLockHoldTimeUnderLoad() {
    // Process 1000 buffers, measure max lock hold time
    // Assert max < 5ms
}

func testGapFillPerformance() {
    // Simulate 100 gaps in rapid succession
    // Assert total processing time < 100ms
}

func testGapFillThrottling() {
    // Fill gap at t=0
    // Attempt fill at t=100ms → should be throttled
    // Attempt fill at t=600ms → should succeed
}
```

---

## References

- Log file: `~/Library/Application Support/Muesli/Logs/muesli-2026-01-25.log`
- Architecture doc: `spec/AEC_architecture.md`
- Original fix plan: `.cursor/plans/aec_offset_validation_fix_407801b6.plan.md`

---

## Review Summary

This plan was reviewed by 7 peer reviewers:
- **6 APPROVE WITH CHANGES**
- **1 REQUEST REVISION**

Key changes from v1 → v2:
1. Reordered investigation steps (quick tests first)
2. Elevated Task spawning fix from "optional" to "REQUIRED"
3. Added success criteria and testing strategy
4. Added investigation for symptoms #2 and #3
5. Made gap fill toggle DEBUG-only with explicit warnings
6. Added throttling guidance for instrumentation
7. Added rollback criteria and baseline measurement requirements
