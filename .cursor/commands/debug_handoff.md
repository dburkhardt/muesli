# Debug Handoff

Generate a handoff summary for an in-progress debugging session so another agent can continue the work.

## Instructions

You're done for the day. Summarize the debugging session so another AI agent can pick up where you left off.

**Output format**: Simple markdown, displayed in chat (for copy/paste to a new session or document).

## Required Sections

Generate a handoff document with these sections:

### 1. Issue Summary
- What bug/issue is being investigated?
- When did it start? What triggered it?
- How does it manifest? (symptoms, error messages, unexpected behavior)

### 2. Context
- Which component(s) are affected?
- Relevant files and code paths
- Any related issues, PRs, or debug logs

### 3. What Was Tried
List everything attempted during this session:
- Approaches that **didn't work** (and why)
- Approaches that **partially worked** (and what's still broken)
- Dead ends to avoid

### 4. Current Hypothesis
- What do you believe is causing the issue?
- What evidence supports this theory?
- What evidence contradicts it?

### 5. Files Modified
- List files changed during this session (check `git status`)
- Note which changes are experimental vs. intentional
- Flag any changes that should be reverted

### 6. Relevant Code Snippets
Include key code sections that are central to the investigation:
- The problematic code
- Any temporary debug code added
- Related code paths

### 7. Next Steps
Prioritized list of what to try next:
1. Most promising approach
2. Alternative approaches
3. Things to investigate further

### 8. Environment Notes
- Any special setup required to reproduce
- Test commands that were useful
- Log locations or debug outputs to check

## Git Context

Before generating the handoff, check:
```bash
git status          # What files are modified?
git diff --stat     # Summary of changes
```

Include a summary of uncommitted changes in the handoff.

## Output Example

```markdown
# Debug Handoff: [Issue Title]

**Date**: YYYY-MM-DD
**Session Duration**: ~X hours
**Status**: In Progress

## Issue Summary

[Description of what's broken and how it manifests]

## Context

- **Component**: [e.g., TranscriptionService, PermissionManager]
- **Related Files**: 
  - `path/to/file1.swift`
  - `path/to/file2.swift`

## What Was Tried

### Didn't Work
- **Approach 1**: [What you tried] → [Why it failed]
- **Approach 2**: [What you tried] → [Why it failed]

### Partially Worked
- **Approach 3**: [What you tried] → [What improved, what's still broken]

## Current Hypothesis

[Your best theory about root cause, with supporting evidence]

## Files Modified

```
M  Muesli/Services/SomeService.swift  (experimental changes)
M  Muesli/ViewModels/SomeViewModel.swift  (keep)
```

## Key Code

[Relevant snippets with file:line references]

## Next Steps

1. [ ] **Try first**: [Most promising next step]
2. [ ] **Alternative**: [Backup approach]
3. [ ] **Investigate**: [Things to look into]

## Environment Notes

- Reproduce with: [commands or steps]
- Check logs at: [log location]
- Useful debug command: [command]
```

## Tips

- **Be thorough**: The next agent has no memory of this session
- **Be honest about dead ends**: Save time by documenting what didn't work
- **Include error messages verbatim**: Don't paraphrase, copy exact text
- **Reference specific lines**: Use `file.swift:123` format
- **Note temporary code**: Flag any debug prints or hacks to remove later
