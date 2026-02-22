# Local Testing Workflow

**Purpose**: Guide for agents to run tests, capture results, and present them to users efficiently.

**Related docs**: `AGENTS.md` (build commands), `MuesliTests/README.md` (test architecture)

---

## Quick Reference

> **CI runs a subset**: GitHub Actions skips ~400 tests (MuesliViewModelTests, TranscriptionServiceTests, FileOutputServiceTests, EchoCancellationServiceTests, CoreAudioTapTests, ModelManagerTests) to keep CI under ~25 min. Run the full suite locally before release.

```bash
# Run all tests included in the shared scheme (currently MuesliTests only)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug test 2>&1 | tee "/tmp/muesli-test-${TIMESTAMP}.txt"

# Run unit tests explicitly
xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug test -only-testing:MuesliTests 2>&1 | tee "test-${TIMESTAMP}.txt"

# Run UI tests (MuesliUITests target exists but is NOT in the shared scheme by default;
# add it to the scheme in Xcode or use -only-testing to include it explicitly)
xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug test -only-testing:MuesliUITests 2>&1 | tee "test-${TIMESTAMP}.txt"

# Run specific test class
xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug test -only-testing:MuesliTests/MuesliViewModelTests 2>&1 | tee "test-${TIMESTAMP}.txt"
```

---

## Testing Workflow for Agents

### 1. Run Tests

**Always use timestamped output files** to preserve test results for later analysis:

```bash
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug test 2>&1 | tee "/tmp/muesli-test-${TIMESTAMP}.txt"
```

> **Note**: The shared scheme (`Muesli.xcscheme`) currently includes only the `MuesliTests` target. `MuesliUITests` exists but is not wired into the shared scheme; use `-only-testing:MuesliUITests` to run UI tests explicitly.

**Why use `tee`?**
- Captures output to file for multiple queries
- Displays real-time progress to user
- Prevents needing to re-run tests to extract different information

**Do NOT:**
- Run tests multiple times just to extract different information
- Rely on terminal scrollback (it gets lost)
- Skip timestamping (prevents confusion with old results)

### 2. Extract Test Results

**After test run completes**, extract results from the saved file (not by re-running):

```bash
# Find the most recent test file
ls -lt test-*.txt | head -1

# Check overall pass/fail status
grep -i "test.*succeeded\|test.*failed" test-<timestamp>.txt

# Count test cases
grep "passed on" test-<timestamp>.txt | wc -l
grep "skipped on" test-<timestamp>.txt | wc -l
grep "failed on" test-<timestamp>.txt | wc -l

# View last 100 lines for summary
tail -100 test-<timestamp>.txt
```

### 3. Present Results to User

**Format**: Always provide a clear, structured summary:

```markdown
## ✅ Test Results Summary

**Status:** `TEST SUCCEEDED` or `TEST FAILED`

- **Total test cases:** [count]
- **Passed:** [count] ✅
- **Skipped:** [count] (with reason if known)
- **Failed:** [count] ❌

### Test Suites Run:
- **[Suite Name]** - Brief description

### [If failures exist] Failed Tests:
- `[TestClass.testMethod()]` - [error summary]

The test output has been saved to `test-[timestamp].txt` for reference.
```

**Example**:

```markdown
## ✅ Test Results Summary

**Status:** `TEST SUCCEEDED`

- **Total test cases:** 133
- **Passed:** 132 ✅
- **Skipped:** 1 (intentional)
- **Failed:** 0 ✅

### Test Suites Run:
- **MuesliViewModelTests** - Comprehensive tests for the main view model
- **RecordingControllerTests** - Recording lifecycle tests
- **ModelManagerTests** - WhisperKit model management tests

The test output has been saved to `test-20260117-232334.txt` for reference.
```

---

## Handling Test Failures

### 1. Identify Failed Tests

```bash
# Extract failed test names
grep "failed on" test-<timestamp>.txt

# Get failure details (context around failures)
grep -B 10 "failed on" test-<timestamp>.txt
```

### 2. Investigate Failure Causes

Common patterns to search for:

```bash
# Assertion failures
grep "XCTAssert" test-<timestamp>.txt | grep -v "passed"

# Swift errors
grep "error:" test-<timestamp>.txt

# Runtime crashes
grep "Fatal error\|Segmentation fault\|EXC_" test-<timestamp>.txt

# Permission issues
grep "TCC\|permission denied\|authorization" test-<timestamp>.txt
```

### 3. Report Failures to User

**Format**:

```markdown
## ❌ Test Failures Detected

**[X]** tests failed:

### Failed: `TestClass.testMethod()`
**Error:** [Brief error message]
**Details:** [Stack trace or relevant context]
**Likely cause:** [Your analysis]
**Suggested fix:** [Recommendation]
```

---

## Test Types and Considerations

### Unit Tests (`MuesliTests/`)

**Characteristics:**
- Fast (run in ~30-60 seconds for full suite)
- No UI interaction required
- Mock-based, isolated components

**When to run:**
- After any code changes
- Before committing
- During development iterations

**Note:** One test is intentionally skipped:
- `testPreferencesManagerOutputDirectory()` - Sandbox/file system test

### UI Tests (`MuesliUITests/`)

**Characteristics:**
- Slower (requires app launch, UI rendering)
- Screenshot-based verification
- Tests full user workflows

**When to run:**
- Before releases
- After UI changes
- When testing user-facing features

**Note:** UI tests may require:
- Screen recording permissions
- Microphone permissions
- Clean test environment

---

## Efficient Test Workflows

### Pattern 1: Full Test Run

**Use when:**
- User explicitly requests "run all tests"
- Before creating PR or release
- After significant refactoring

**Steps:**
1. Run full test suite with timestamped output
2. Wait for completion (exit code 0 = success)
3. Extract summary statistics
4. Present formatted results
5. Reference saved file for detailed analysis if needed

### Pattern 2: Targeted Test Run

**Use when:**
- Testing specific component changes
- Debugging a particular feature
- Iterating on a single test

**Steps:**
1. Run specific test class/method
2. Capture to timestamped file
3. Show relevant failures immediately
4. Suggest next steps

```bash
# Example: Test only the ViewModel
xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug test \
  -only-testing:MuesliTests/MuesliViewModelTests 2>&1 | tee "test-${TIMESTAMP}.txt"
```

### Pattern 3: Continuous Development

**Use when:**
- Making iterative code changes
- TDD workflow
- Debugging failures

**Steps:**
1. Make code change
2. Run relevant tests (not full suite)
3. Fix failures
4. Run full suite before finalizing
5. Clean build if needed: `xcodebuild clean`

---

## Common Issues and Solutions

### Issue: Tests Time Out

**Symptoms:** Tests hang indefinitely
**Cause:** Async operations not completing, deadlock
**Solution:**
```bash
# Kill hanging test process
killall xctest

# Check for running instances
ps aux | grep Muesli

# Clean and retry
xcodebuild clean
```

### Issue: Permission Prompts Block Tests

**Symptoms:** Tests pause waiting for user interaction
**Cause:** TCC permissions not granted for test bundle
**Solution:**
```bash
# Grant permissions to test bundle
# Note: May need to run tests once to trigger prompts
# Then manually grant in System Settings → Privacy & Security
```

### Issue: Stale Test Results

**Symptoms:** Tests pass locally but fail in CI, or vice versa
**Cause:** Cached test data, DerivedData issues
**Solution:**
```bash
# Clean DerivedData
rm -rf ~/Library/Developer/Xcode/DerivedData/Muesli-*

# Clean and rebuild
xcodebuild clean
xcodebuild build
xcodebuild test
```

### Issue: Xcode Version Mismatch

**Symptoms:** Build errors, API availability issues
**Cause:** Tests require specific Xcode version
**Solution:**
```bash
# Check Xcode version
xcodebuild -version

# Expected: Xcode 26.0 or later
# Update Xcode if needed
```

---

## Performance Considerations

### Test Execution Times (Approximate)

- **Full test suite:** 1-2 minutes
- **Unit tests only:** 30-60 seconds
- **UI tests only:** 1-3 minutes
- **Single test class:** 5-15 seconds

### Optimization Tips

1. **Run targeted tests during development** - Don't run full suite on every change
2. **Use parallel testing** - xcodebuild supports parallel test execution (default)
3. **Skip UI tests for quick iterations** - Run unit tests first, UI tests before commit
4. **Cache test results** - Save output files to avoid re-running for analysis

---

## Integration with Git Workflow

### Pre-Commit Testing

**Before committing code:**

```bash
# Run relevant tests
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
xcodebuild test 2>&1 | tee "/tmp/muesli-test-${TIMESTAMP}.txt"

# Verify success
if grep -q "TEST SUCCEEDED" "/tmp/muesli-test-${TIMESTAMP}.txt"; then
  echo "✅ Tests passed - safe to commit"
else
  echo "❌ Tests failed - fix before committing"
  exit 1
fi
```

### Pre-PR Testing

**Before creating pull request:**

```bash
# Full test suite including UI tests
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug test 2>&1 | tee "/tmp/muesli-test-${TIMESTAMP}.txt"

# Generate test summary for PR description
grep "passed on\|skipped on\|failed on" "/tmp/muesli-test-${TIMESTAMP}.txt" | wc -l
```

### Pre-Release Testing

**Before tagging a release:**

1. Run full test suite (unit + UI)
2. Verify all tests pass (except intentionally skipped)
3. Check test output for warnings
4. Document any skipped tests in release notes
5. Archive test results with release tag

---

## Agent Best Practices

### DO:
- ✅ Always capture test output to timestamped files
- ✅ Present clear, formatted summaries to users
- ✅ Investigate failures before reporting
- ✅ Run targeted tests during development
- ✅ Run full suite before major commits
- ✅ Reference saved files for detailed analysis
- ✅ Use parallel tool calls when reading test files

### DON'T:
- ❌ Re-run tests just to extract different information
- ❌ Show raw xcodebuild output to users (too verbose)
- ❌ Skip timestamping output files
- ❌ Assume test failures without investigating
- ❌ Run full suite on every minor change (inefficient)
- ❌ Forget to check exit codes (0 = success, non-zero = failure)

### Reporting Template

When user asks to "run tests", follow this workflow:

1. **Run tests** with timestamped output
2. **Wait** for completion
3. **Extract** summary statistics from saved file
4. **Format** results in markdown table
5. **Report** status clearly (SUCCEEDED/FAILED)
6. **Investigate** failures if any
7. **Suggest** next steps

---

## Quick Troubleshooting Guide

| Symptom | Diagnosis | Solution |
|---------|-----------|----------|
| `xcodebuild: command not found` | Xcode not installed | Install Xcode from App Store |
| `Unable to find a destination` | Simulator/device issues | Specify `-destination 'platform=macOS'` |
| `Permission denied` errors | TCC permissions | Grant in System Settings |
| Tests hang indefinitely | Async timeout/deadlock | Kill process, check test logic |
| Random test failures | Race conditions | Review async test code |
| All tests fail | Build issues | Run `xcodebuild clean build` first |
| UI tests fail | Screenshot mismatches | Update reference images or check UI changes |

---

## Examples

### Example 1: User Requests Full Test Run

**User:** "Run all tests"

**Agent Actions:**
```bash
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug test 2>&1 | tee "/tmp/muesli-test-${TIMESTAMP}.txt"
```

**Agent Response:**
```markdown
## ✅ Test Results Summary

**Status:** `TEST SUCCEEDED`

- **Total test cases:** 133
- **Passed:** 132 ✅
- **Skipped:** 1
- **Failed:** 0 ✅

All tests are passing! The test output has been saved to `test-20260117-232334.txt`.
```

### Example 2: User Reports Bug, Agent Verifies Tests

**User:** "There's a bug in the recording controller"

**Agent Actions:**
```bash
# Run targeted test suite
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug test \
  -only-testing:MuesliTests/RecordingControllerTests 2>&1 | tee "test-${TIMESTAMP}.txt"

# Analyze results
grep "RecordingControllerTests" "/tmp/muesli-test-${TIMESTAMP}.txt"
```

**Agent Response:**
```markdown
I've run the RecordingController test suite to verify the issue. All 12 tests are passing, which suggests the bug might be environmental or specific to a particular scenario not covered by tests.

Could you provide more details about:
- Steps to reproduce the bug
- Expected vs actual behavior
- Any error messages you're seeing?

This will help me write a regression test and fix the issue.
```

### Example 3: Agent Makes Code Changes

**Agent Workflow:**

1. Make code changes to fix issue
2. Run relevant tests to verify fix
3. Run full test suite to ensure no regressions
4. Report results

```bash
# After making changes
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
xcodebuild test 2>&1 | tee "/tmp/muesli-test-${TIMESTAMP}.txt"

# Verify
grep "TEST SUCCEEDED" "/tmp/muesli-test-${TIMESTAMP}.txt"
```

**Agent Response:**
```markdown
I've fixed the issue and verified the solution:

**Changes made:**
- Updated RecordingController to handle edge case
- Added null check in audio callback

**Test results:**
- All 133 tests passing ✅
- No regressions introduced ✅

The fix is ready for commit.
```

---

## Summary

**Key Principles:**
1. **Always timestamp** test output files
2. **Never re-run** tests just to extract info (use saved files)
3. **Present clear summaries** to users (not raw output)
4. **Run appropriate scope** (targeted for dev, full for commits)
5. **Investigate failures** before reporting
6. **Reference documentation** for context

**Standard Workflow:**
1. Run → 2. Capture → 3. Extract → 4. Format → 5. Present

By following this workflow, agents can efficiently manage testing, provide clear feedback to users, and maintain high code quality throughout development.
