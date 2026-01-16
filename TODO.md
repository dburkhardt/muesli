# TODO & Future Features

This file tracks features, improvements, and fixes to implement later.

## Format
Each item should include:
- **Category** (Feature/Enhancement/Bug/Refactor)
- **Priority** (High/Medium/Low)
- **Description**
- **Notes** (optional context)

---

## Backlog

### Features

*No items yet*

### Enhancements

*No items yet*

### Bugs

**[Bug]** [High] Handle blank audio and random snippets properly
- Description: Ensure blank audio segments and random snippets at the end of meetings are handled correctly
- Occurs in two scenarios:
  1. End of live meetings - may capture trailing silence or brief noise
  2. During reprocessing - should skip/filter empty or spurious audio chunks
- Notes: Need to add audio detection/filtering logic in transcription pipeline
- Related: TranscriptionService.swift, TranscriptProcessor.swift

### Refactoring

*No items yet*

---

## Example Entry

**[Feature]** [High] Add keyboard shortcuts for recording controls
- Notes: Cmd+R to start/stop, Cmd+P to pause/resume
- Related: See SPEC.md Phase X

---

## Completed

Archive completed items here with completion date.

