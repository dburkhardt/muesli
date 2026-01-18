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

**[Enhancement]** [Medium] Add visuals to website
- Description: Add screenshots, GIFs, or videos demonstrating the app in action to the website
- Notes: Show key features like onboarding, recording in progress, transcript view, meeting history
- Consider animated GIF of full workflow or individual screenshots for each major feature
- Related: docs/index.html, docs/assets/
- Status: UI test infrastructure created in v0.1.2, screenshots can be generated from tests

**[Enhancement]** [Low] Make reprocessing chunk size configurable in preferences
- Description: Add preference setting to allow users to configure chunk size specifically for reprocessing transcripts
- Notes: Currently reprocessing uses the same audio chunk duration setting as live recording. Consider whether to use the same setting or add a separate "reprocessing chunk duration" preference
- May want different chunk sizes for reprocessing vs live recording (e.g., larger chunks for better accuracy when latency doesn't matter)
- Related: PreferencesView.swift, PreferencesManager.swift, RecordingDetailView.swift, CompletedMeetingWindow.swift

### Bugs

*No items - All high-priority bugs fixed in v0.1.2*

### Refactoring

**[Refactor]** [Low] Enforce SwiftLint in CI
- Description: Fix all existing lint violations and remove continue-on-error from CI
- Notes: Currently advisory only. Need baseline cleanup first before enforcing strict mode.
- Related: .swiftlint.yml, .github/workflows/ci.yml

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

### v0.1.2 - 2026-01-18

**[Enhancement]** Add configurable audio chunking duration preference
- Completed: User-adjustable slider in preferences (2-10 seconds)
- Files: PreferencesView.swift, PreferencesManager.swift, AppStorageKeys.swift

**[Enhancement]** Add live transcript refinement
- Completed: Infrastructure added for real-time refinement during recording
- Files: TranscriptionCoordinator.swift, RefinementCoordinator.swift
- Notes: Backend support complete, UI activation to come in future release

**[Enhancement]** Add copy transcript to clipboard button
- Completed: Copy button with plain text and Markdown format options
- Files: ClipboardHelper.swift, RecordingDetailView.swift, CompletedMeetingWindow.swift

**[Enhancement]** Improve DMG installer appearance
- Completed: Custom SVG background with app icon, arrow, installation instructions
- Files: assets/dmg-background.svg, scripts/create-dmg-modern.sh

**[Bug]** Onboarding instant permission updates
- Completed: Real-time monitoring with distributed notifications + polling fallback
- Files: PermissionManager.swift, OnboardingView.swift

**[Bug]** Handle blank audio and random snippets
- Completed: Hallucination filter added to TranscriptProcessor
- Files: TranscriptProcessor.swift
- Filters: "thank you", "subscribe", repetitive text, common filler words

**[Refactor]** UI Testing Framework
- Completed: XCUITest suite for screenshot capture
- Files: MuesliUITests/ directory with test files and helpers
- Supports: Light/dark modes, mocked permissions, fixture data

**[Refactor]** SwiftLint Configuration
- Completed: Code quality standards configured
- File: .swiftlint.yml
- Status: Advisory mode (will enforce in future release)
