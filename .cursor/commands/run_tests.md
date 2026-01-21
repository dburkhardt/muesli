# Run Tests

Run the test suite for Muesli and present formatted results.

## Command

```bash
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

## Variants

### Run Unit Tests Only

```bash
TIMESTAMP=$(date +%Y%m%d-%H%M%S) && \
xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug test \
  -only-testing:MuesliTests 2>&1 | tee "/tmp/muesli-test-${TIMESTAMP}.txt"
```

### Run UI Tests Only

```bash
TIMESTAMP=$(date +%Y%m%d-%H%M%S) && \
xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug test \
  -only-testing:MuesliUITests 2>&1 | tee "/tmp/muesli-test-${TIMESTAMP}.txt"
```

### Run Specific Test Class

```bash
TIMESTAMP=$(date +%Y%m%d-%H%M%S) && \
xcodebuild -project Muesli.xcodeproj -scheme Muesli -configuration Debug test \
  -only-testing:MuesliTests/MuesliViewModelTests 2>&1 | tee "/tmp/muesli-test-${TIMESTAMP}.txt"
```

## Usage

### As Cursor Command

1. Open Command Palette (Cmd+Shift+P)
2. Type "Run Tests"
3. Select this command
4. View results in terminal

### For Agents

When a user requests test execution:

1. Run the main command above
2. Wait for completion (do not interrupt)
3. Extract results from the generated `/tmp/muesli-test-{timestamp}.txt` file
4. Format and present results using the template below

## Result Format Template

```markdown
## ✅ Test Results Summary

**Status:** `TEST SUCCEEDED`

- **Total test cases:** {total}
- **Passed:** {passed} ✅
- **Skipped:** {skipped}
- **Failed:** {failed} ❌

### Test Suites Run:
- **MuesliTests** - Unit tests for core functionality
- **MuesliUITests** - UI and integration tests

{if failures exist:}
### Failed Tests:
- `{TestClass.testMethod()}` - {error summary}

The test output has been saved to `/tmp/muesli-test-{timestamp}.txt` for reference.
```

## Expected Output

### Successful Run

```
✅ Status: SUCCEEDED
📊 Passed: 132
⏭️  Skipped: 1
❌ Failed: 0
📁 Output saved to: /tmp/muesli-test-20260117-232334.txt
```

### Failed Run

```
❌ Status: FAILED
📁 Output saved to: /tmp/muesli-test-20260117-232334.txt

Failed tests:
Test case 'MuesliViewModelTests.testRecordingPreconditions()' failed on 'My Mac'
Test case 'RecordingControllerTests.testAudioCallback()' failed on 'My Mac'
```

## Workflow

### For Agents

Follow the complete workflow documented in [`spec/local_testing_workflow.md`](../spec/local_testing_workflow.md):

1. **Run** - Execute test command with timestamped output
2. **Capture** - Save to `/tmp/muesli-test-{timestamp}.txt` file
3. **Extract** - Parse results from saved file (do NOT re-run)
4. **Format** - Use template above for clear presentation
5. **Present** - Show summary to user with next steps

### Best Practices

✅ **DO:**
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

## Troubleshooting

### Tests Hang

```bash
# Kill hung processes
killall xctest
killall Muesli

# Clean and retry
xcodebuild clean
```

### Permission Issues

```bash
# Reset TCC permissions
tccutil reset ScreenCapture com.muesli.app
tccutil reset Microphone com.muesli.app

# Re-run tests (will prompt for permissions)
```

### Build Failures

```bash
# Clean DerivedData
rm -rf ~/Library/Developer/Xcode/DerivedData/Muesli-*

# Clean build
xcodebuild clean build
```

### Stale Results

```bash
# Clean previous test artifacts
rm -rf ~/Library/Developer/Xcode/DerivedData/Muesli-*/Build/Products/Debug/MuesliTests.xctest
rm -rf ~/Library/Developer/Xcode/DerivedData/Muesli-*/Build/Products/Debug/MuesliUITests.xctest

# Rebuild and test
xcodebuild clean build test
```

## Integration

### Pre-Commit Hook

Add to `.git/hooks/pre-commit`:

```bash
#!/bin/bash
echo "Running tests..."
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
xcodebuild test 2>&1 | tee "/tmp/muesli-test-${TIMESTAMP}.txt"

if ! grep -q "TEST SUCCEEDED" "/tmp/muesli-test-${TIMESTAMP}.txt"; then
  echo "❌ Tests failed. Commit aborted."
  exit 1
fi

echo "✅ Tests passed. Proceeding with commit."
```

### CI/CD (GitHub Actions)

```yaml
- name: Run Tests
  run: |
    xcodebuild test \
      -project Muesli.xcodeproj \
      -scheme Muesli \
      -configuration Debug
```

## Related Documentation

- [`spec/local_testing_workflow.md`](../spec/local_testing_workflow.md) - Complete testing workflow guide
- [`AGENTS.md`](../AGENTS.md) - Build and test commands
- [`MuesliTests/README.md`](../MuesliTests/README.md) - Test architecture
- [`MuesliUITests/README.md`](../MuesliUITests/README.md) - UI test documentation

## Performance

**Expected execution times:**
- Full test suite: 1-2 minutes
- Unit tests only: 30-60 seconds
- UI tests only: 1-3 minutes
- Single test class: 5-15 seconds

## Exit Codes

- `0` - All tests passed
- `Non-zero` - Tests failed or build error

Check exit code in scripts:

```bash
if [ $? -eq 0 ]; then
  echo "Tests passed"
else
  echo "Tests failed"
  exit 1
fi
```

## Quick Reference

| Command | Purpose | Duration |
|---------|---------|----------|
| `xcodebuild test` | Run all tests | 1-2 min |
| `xcodebuild test -only-testing:MuesliTests` | Unit tests only | 30-60 sec |
| `xcodebuild test -only-testing:MuesliUITests` | UI tests only | 1-3 min |
| `xcodebuild test -only-testing:MuesliTests/ClassName` | Specific class | 5-15 sec |

## Example Agent Usage

```
User: "Run all tests"

Agent:
1. Execute test command with timestamp
2. Wait for completion
3. Extract from /tmp/muesli-test-{timestamp}.txt:
   - grep "TEST SUCCEEDED"
   - Count passed/skipped/failed
4. Present formatted summary:
   ✅ Status: SUCCEEDED
   📊 132 passed, 1 skipped, 0 failed
5. Reference saved file for details
```

---

**Last Updated:** 2026-01-18  
**Maintainer:** See AGENTS.md for contact
