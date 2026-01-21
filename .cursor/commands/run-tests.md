# Run Tests

Run the Muesli test suite and present formatted results.

## Instructions

1. **Execute the test command** with timestamped output (preferably with progress bar)
2. **Wait for completion** (do not interrupt the test run)
3. **Extract results** from the generated `/tmp/muesli-test-{timestamp}.txt` file
4. **Format and present** results using the template below

## Command (with Progress Bar) ⭐ Recommended

**Use the progress bar script for better visibility:**

```bash
cd /Users/dburkhardt/git-repos/muesli && ./scripts/run-tests-with-progress.sh
```

This will:
- Enumerate tests first to show total count
- Display a tqdm-like progress bar: `[████████░░░░] 45% (23/50) testMethodName`
- Show current test name being executed
- Present formatted summary at the end

## Command (Standard - No Progress Bar)

For standard output without progress bar:

```bash
cd /Users/dburkhardt/git-repos/muesli && \
TIMESTAMP=$(date +%Y%m%d-%H%M%S) && \
xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug test 2>&1 | tee "/tmp/muesli-test-${TIMESTAMP}.txt" && \
echo "--- TEST SUMMARY ---" && \
if grep -q "TEST SUCCEEDED" "/tmp/muesli-test-${TIMESTAMP}.txt"; then \
  echo "✅ Status: SUCCEEDED" && \
  echo "📊 Passed: $(grep 'passed on' /tmp/muesli-test-${TIMESTAMP}.txt | wc -l | tr -d ' ')" && \
  echo "⏭️  Skipped: $(grep 'skipped on' /tmp/muesli-test-${TIMESTAMP}.txt | wc -l | tr -d ' ')" && \
  echo "❌ Failed: $(grep 'failed on' /tmp/muesli-test-${TIMESTAMP}.txt | wc -l | tr -d ' ')" && \
  echo "📁 Output saved to: /tmp/muesli-test-${TIMESTAMP}.txt"; \
else \
  echo "❌ Status: FAILED" && \
  echo "📁 Output saved to: /tmp/muesli-test-${TIMESTAMP}.txt" && \
  echo "" && \
  echo "Failed tests:" && \
  grep 'failed on' "/tmp/muesli-test-${TIMESTAMP}.txt" | head -10; \
fi
```

## Result Format Template

After running tests, extract results from the saved file and present:

```markdown
## ✅ Test Results Summary

**Status:** `TEST SUCCEEDED` or `TEST FAILED`

- **Total test cases:** {extract from output}
- **Passed:** {count} ✅
- **Skipped:** {count}
- **Failed:** {count} ❌

### Test Suites Run:
- **MuesliTests** - Unit tests for core functionality
- **MuesliUITests** - UI and integration tests

{if failures exist:}
### Failed Tests:
- `{TestClass.testMethod()}` - {error summary}

The test output has been saved to `/tmp/muesli-test-{timestamp}.txt` for reference.
```

## Variants

### Run Unit Tests Only (with Progress Bar)

```bash
cd /Users/dburkhardt/git-repos/muesli && ./scripts/run-tests-with-progress.sh --unit-only
```

### Run UI Tests Only (with Progress Bar)

```bash
cd /Users/dburkhardt/git-repos/muesli && ./scripts/run-tests-with-progress.sh --ui-only
```

### Run Specific Test Class (with Progress Bar)

```bash
cd /Users/dburkhardt/git-repos/muesli && ./scripts/run-tests-with-progress.sh --class ClassName
```

### Standard Variants (No Progress Bar)

```bash
# Unit tests only
cd /Users/dburkhardt/git-repos/muesli && \
TIMESTAMP=$(date +%Y%m%d-%H%M%S) && \
xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug test \
  -only-testing:MuesliTests 2>&1 | tee "/tmp/muesli-test-${TIMESTAMP}.txt"

# UI tests only
cd /Users/dburkhardt/git-repos/muesli && \
TIMESTAMP=$(date +%Y%m%d-%H%M%S) && \
xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug test \
  -only-testing:MuesliUITests 2>&1 | tee "/tmp/muesli-test-${TIMESTAMP}.txt"

# Specific test class
cd /Users/dburkhardt/git-repos/muesli && \
TIMESTAMP=$(date +%Y%m%d-%H%M%S) && \
xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug test \
  -only-testing:MuesliTests/ClassName 2>&1 | tee "/tmp/muesli-test-${TIMESTAMP}.txt"
```

## Progress Bar Features

The progress bar script (`run-tests-with-progress.sh`) provides:

- **Visual progress**: `[████████░░░░] 45% (23/50)` format similar to Python's tqdm
- **Current test display**: Shows which test is currently running
- **Real-time updates**: Progress bar updates every 0.3 seconds
- **Fallback mode**: If test enumeration fails, shows running count instead
- **Full output capture**: Still saves complete output to `/tmp/muesli-test-{timestamp}.txt`

## Best Practices

✅ **DO:**
- Use the progress bar script for better visibility
- Use timestamped output files
- Wait for complete test run before analyzing
- Present formatted summaries
- Reference saved file for details
- Run targeted tests during development
- Run full suite before commits

❌ **DON'T:**
- Re-run tests to extract different info
- Show raw xcodebuild output to users
- Skip capturing to file
- Interrupt test runs
- Run full suite on every minor change

## Expected Execution Times

- Full test suite: 1-2 minutes
- Unit tests only: 30-60 seconds
- UI tests only: 1-3 minutes
- Single test class: 5-15 seconds

## Troubleshooting

### Tests Hang

```bash
killall xctest
killall Muesli
xcodebuild clean
```

### Permission Issues

```bash
tccutil reset ScreenCapture com.muesli.app
tccutil reset Microphone com.muesli.app
```

### Build Failures

```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/Muesli-*
xcodebuild clean build
```

### Progress Bar Not Showing

If the progress bar doesn't appear:
- Ensure terminal supports ANSI escape codes
- Check that `jq` is installed for JSON parsing (optional, script will fallback)
- Try the standard command without progress bar

## Related Documentation

- [`scripts/run-tests-with-progress.sh`](../../scripts/run-tests-with-progress.sh) - Progress bar script implementation
- [`commands/run_tests.md`](../../commands/run_tests.md) - Detailed test documentation
- [`spec/local_testing_workflow.md`](../../spec/local_testing_workflow.md) - Complete testing workflow guide
- [`AGENTS.md`](../../AGENTS.md) - Build and test commands
