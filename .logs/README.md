# Build and Test Logs

This directory contains timestamped build and test logs from local development.

## Contents

- `build-*.txt` - Build output from xcodebuild
- `test-*.txt` - Test output from xcodebuild
- `coverage-*.txt` - Test output with coverage enabled

## Purpose

Logs are saved here to:
- Keep the repository root clean
- Preserve timestamped build/test history for debugging
- Allow grepping logs without re-running builds

## Usage

```bash
# Save a build log
xcodebuild ... build 2>&1 | tee ".logs/build-$(date +%Y%m%d-%H%M%S).txt"

# Search recent logs
grep "error:" .logs/build-*.txt | tail -20
```

## Cleanup

This directory is gitignored and can be safely deleted:

```bash
rm -rf .logs/
```

Logs will be recreated on the next build/test run.
