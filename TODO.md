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

**[Feature]** [Medium] Add automatic speaker detection
- Description: Implement automatic speaker detection to identify and label different speakers in the transcript
- Notes: Research speaker diarization techniques compatible with WhisperKit or as post-processing step

**[Feature]** [Medium] Add database structure for searchable meeting notes
- Description: Create a database structure that makes searching meeting notes possible
- Notes: Consider SQLite or other embedded database options for indexing transcripts and metadata

**[Feature]** [Low] Create Google Drive integration for cloud syncing
- Description: Add integration into Google Drive to enable cloud syncing of recordings and transcripts
- Notes: Requires OAuth setup, API integration, and user preference for opt-in

**[Feature]** [Low] Add option to use cloud transcription APIs
- Description: Provide alternative to local WhisperKit transcription using cloud APIs (e.g., OpenAI Whisper API, Google Speech-to-Text)
- Notes: Should be opt-in preference, requires API key management

### Enhancements

**[Enhancement]** [Medium] Add configurable audio chunking duration preference
- Description: Add option in preferences page to alter the length of audio chunking (2-10 seconds, integer values only)
- Notes: Currently hardcoded in TranscriptionService, should be user-configurable via PreferencesManager
- Related: TranscriptionService.swift, PreferencesView.swift, PreferencesManager.swift

**[Enhancement]** [High] Add live transcript refinement
- Description: Implement live refinement of the transcript to clean up and stitch audio chunks together
- Notes: Use LLM to improve readability, fix obvious errors, and create coherent sentences from chunks
- Related: Existing TranscriptRefinementService.swift, may need real-time variant

**[Enhancement]** [Medium] Add copy transcript to clipboard button
- Description: Add a button to make it easy to copy the entire transcript to clipboard
- Notes: Should be accessible from transcript view, consider adding formatting options (plain text vs markdown)

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

