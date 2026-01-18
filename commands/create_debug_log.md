# Create Debug Log

Creates a new debug log file in `docs/debug-logs/` with today's date and the standard template.

## Usage

This command creates a timestamped debug log file for documenting a debugging session.

### Steps

1. Run this command from the Cursor command palette
2. When prompted, provide a short description (e.g., "audio-glitch", "permission-issue")
3. The command will:
   - Create `docs/debug-logs/YYYY-MM-DD_description.md`
   - Copy the template structure
   - Open the file for editing

### Manual Creation

If you prefer to create the file manually:

```bash
# Create the file with today's date
cd /Users/dburkhardt/git-repos/muesli
DATE=$(date +%Y-%m-%d)
DESCRIPTION="short-description"
cp docs/debug-logs/template.md "docs/debug-logs/${DATE}_${DESCRIPTION}.md"

# Open in editor
code "docs/debug-logs/${DATE}_${DESCRIPTION}.md"
```

### After Creating

1. Fill in all template sections:
   - **Date & Time**: When the issue occurred
   - **Category**: Which component (Audio, Permissions, Transcription, etc.)
   - **Problem Description**: What was broken
   - **Symptoms**: What you observed
   - **Root Cause**: Why it happened
   - **Fix Description**: How you fixed it
   - **Affected Files**: What files changed
   - **Code Snippets**: Before/after comparisons

2. Update the index in `docs/debug-logs/README.md`:
   - Add entry under the appropriate year/month
   - Include date, title, and one-line summary
   - Keep in reverse chronological order

3. Cross-reference with regression tests if applicable:
   - Link to test in `MuesliTests/RegressionTests.swift`
   - Add link from test back to debug log

## Template Sections

The debug log template includes:

- **Date & Time**: Timestamp of when the issue occurred
- **Category**: Component affected (Audio, Permissions, UI, etc.)
- **Problem Description**: High-level summary
- **Symptoms/Error Messages**: Observable behavior, console output
- **Root Cause Analysis**: Why it happened
- **Fix Description**: How it was resolved
- **Affected Files**: List of modified files
- **Code Snippets**: Before/after code comparisons
- **Prevention/Testing**: Regression tests, documentation updates
- **Related Issues/PRs**: Cross-references
- **Notes**: Additional context

## Tips

- **Be specific**: Include exact error messages and logs
- **Be thorough**: Future you (or another developer) should be able to understand the issue without context
- **Link to tests**: Cross-reference regression tests that prevent this from recurring
- **Use code references**: Include line numbers when citing existing code
- **Keep it concise**: Focus on the essential information

## Example File Names

- `2026-01-15_screen-recording-permission-detection.md`
- `2026-01-16_audio-buffer-overflow.md`
- `2026-01-18_transcription-cancellation.md`
- `2026-01-20_window-management-race-condition.md`

## See Also

- Template: [`docs/debug-logs/template.md`](../docs/debug-logs/template.md)
- Index: [`docs/debug-logs/README.md`](../docs/debug-logs/README.md)
- Regression Tests: [`MuesliTests/RegressionTests.swift`](../MuesliTests/RegressionTests.swift)
