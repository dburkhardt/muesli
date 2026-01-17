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
- Description: Create a database structure that makes searching meeting notes possible, with MCP server integration
- Notes: Consider SQLite or other embedded database options for indexing transcripts and metadata
- MCP Integration: Expose transcript data via Model Context Protocol so other local tools can query and access meeting information
- Related: Research MCP server implementation patterns for Swift

**[Feature]** [Low] Create Google Drive integration for cloud syncing
- Description: Add integration into Google Drive to enable cloud syncing of recordings and transcripts
- Notes: Requires OAuth setup, API integration, and user preference for opt-in

**[Feature]** [Low] Add option to use cloud transcription APIs
- Description: Provide alternative to local WhisperKit transcription using cloud APIs (e.g., OpenAI Whisper API, Google Speech-to-Text)
- Notes: Should be opt-in preference, requires API key management

**[Feature]** [Medium] Add Outlook calendar integration
- Description: Integrate with local Outlook app to automatically link recordings to calendar events
- Notes: Must work locally without cloud API access - use macOS scripting bridge or AppleScript to access Outlook data
- Implementation: Detect Outlook.app running locally, query calendar via ScriptingBridge, match meeting times to recordings
- Related: Similar pattern to MeetingAppDetector.swift, requires Outlook.app to be open

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

**[Enhancement]** [Low] Improve DMG installer appearance
- Description: Make the DMG download folder pretty with custom icon and nice background for drag-to-Applications instruction
- Notes: Use create-dmg or similar tool to add custom background image, positioned icons, and window styling
- Related: scripts/create-dmg.sh

**[Enhancement]** [Medium] Add visuals to website
- Description: Add screenshots, GIFs, or videos demonstrating the app in action to the website
- Notes: Show key features like onboarding, recording in progress, transcript view, meeting history
- Consider animated GIF of full workflow or individual screenshots for each major feature
- Related: docs/index.html, docs/assets/

### Bugs

**[Bug]** [High] Onboarding should instantly update when screen recording permission is approved
- Description: When user approves screen recording permissions in System Settings, the onboarding pane should immediately show a green checkmark without requiring app restart
- Notes: Currently requires quitting and reopening the app to see permission status update. Need to implement real-time permission monitoring or more aggressive polling when permission screen is active
- Related: OnboardingView.swift, PermissionManager.swift

**[Bug]** [High] Handle blank audio and random snippets properly
- Description: Ensure blank audio segments and random snippets at the end of meetings are handled correctly
- Occurs in two scenarios:
  1. End of live meetings - may capture trailing silence or brief noise
  2. During reprocessing - should skip/filter empty or spurious audio chunks
- Notes: Need to add audio detection/filtering logic in transcription pipeline
- Related: TranscriptionService.swift, TranscriptProcessor.swift

### Refactoring

**[Refactor]** [Low] Use GitHub milestones and project plans for release management
- Description: Implement GitHub milestones and project plans to better organize and track release cycles
- Notes: Would provide better visibility into what features/fixes are planned for each release version, integrate with PR workflow
- Related: .github/workflows/release.yml, git_workflow.md

**[Refactor]** [Medium] Investigate sandboxed build and launch for agent testing
- Description: Research and implement ways to build and launch the app in a sandbox environment that AI agents can interact with
- Notes: Would enable agents to test permission flows, inspect UI for visual errors, verify onboarding screens, and test recording functionality
- Potential approaches: Headless testing frameworks, UI automation APIs, screenshot comparison tools, virtual display environments
- Related: Testing infrastructure, CI/CD workflows

**[Refactor]** [Medium] Create integration tests with paired audio/transcript fixtures
- Description: Build test suite that uses known audio files with expected transcripts to verify end-to-end transcription accuracy
- Notes: Create fixture directory with sample audio files (CAF format) and their expected transcript outputs
- Tests should verify: audio processing pipeline, transcription accuracy, timestamp generation, file output format
- Related: MuesliTests/, TranscriptionService.swift, AudioCaptureService.swift

---

## Example Entry

**[Feature]** [High] Add keyboard shortcuts for recording controls
- Notes: Cmd+R to start/stop, Cmd+P to pause/resume
- Related: See SPEC.md Phase X

---

## Completed

Archive completed items here with completion date.

