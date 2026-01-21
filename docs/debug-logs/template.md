# [Short Descriptive Title]

**Date**: YYYY-MM-DD HH:MM
**Category**: [Audio | Permissions | Transcription | UI | Recording | File I/O | Models | Echo Cancellation | LLM]

## Problem Description

[High-level summary of the issue - what was broken or not working as expected?]

## Symptoms/Error Messages

[What did users/developers observe? Include:]
- User-visible behavior
- Console logs/error messages
- Specific conditions that triggered the issue
- Screenshots if applicable

```
[Error messages, stack traces, or relevant log output]
```

## Root Cause Analysis

[Why did this happen? What was the underlying cause?]
- Incorrect assumption about API behavior
- Missing error handling
- Race condition
- Wrong configuration
- Architectural issue
- etc.

## Fix Description

[How was the problem resolved?]
- What approach was taken
- Why this solution was chosen
- Any trade-offs or limitations

## Affected Files

- `path/to/file1.swift` - [brief description of change]
- `path/to/file2.swift` - [brief description of change]
- `path/to/file3.swift` - [brief description of change]

## Code Snippets

### Before

```swift
// Code that had the bug
func problematicFunction() {
    // Old implementation
}
```

### After

```swift
// Fixed code
func problematicFunction() {
    // New implementation with fix
}
```

## Prevention/Testing

[How can we prevent this from happening again?]
- Regression test added? (link to test file/method)
- Documentation updated?
- Architecture changed?
- Code review checklist item?

## Related Issues/PRs

- Regression test: `MuesliTests/RegressionTests.swift` - `testMethodName()`
- Related GitHub issue: #123
- Related debug log: `YYYY-MM-DD_description.md`

## Notes

[Additional context, learnings, or follow-up items]
- Things to watch out for
- Known limitations of the fix
- Future improvements
