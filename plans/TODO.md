# TODO & Future Features

This file tracks features, improvements, and fixes to implement later.

## Format
Each item should include:
- **Category** (Feature/Enhancement/Bug/Refactor)
- **Priority** (High/Medium/Low)
- **Description**
- **Notes** (optional context)

---

## In Progress (v0.1.2 Polish)

**[Enhancement]** [High] Capture and publish app screenshots for website
- Description: Execute UI tests to capture screenshots and add them to website
- Notes: Now that UI test infrastructure exists, run screenshot tests and publish results
  - Run MuesliUITests in both light and dark modes
  - Capture: onboarding flow, recording in progress, transcript view, meeting history, preferences
  - Optimize images for web (compress, proper dimensions)
  - Add to docs/assets/screenshots/
  - Update docs/index.html to display screenshots
- Commands:
  - Run tests: xcodebuild test -scheme Muesli -testPlan MuesliUITests
  - Screenshots saved to: ~/Library/Developer/Xcode/DerivedData/.../Attachments/
- Related: MuesliUITests/, docs/index.html, docs/assets/screenshots/
- Status: UI test infrastructure complete, ready to capture and publish

**[Refactor]** [Medium] Create testing instruction generator for releases/branches
- Description: Add automated mechanism to generate clear, user-friendly testing instructions based on branch changes or release version
- Notes: Should analyze git diff or CHANGELOG and create structured test plan with:
  - What changed (user-facing features/fixes)
  - Step-by-step testing instructions
  - Expected behavior/results
  - Edge cases to check
- Potential approaches:
  - Script that parses CHANGELOG.md and generates test-instructions.md
  - GitHub Actions workflow to auto-generate testing checklist on PR/release
  - Template in docs/ that gets populated with release-specific instructions
- Would help QA testing and pre-release validation
- Related: CHANGELOG.md, spec/*, AGENTS.md release checklist
- Status: Spec document started (spec/local_testing_workflow.md)

---

## Backlog

### Features

**[Feature]** [Medium] Add automatic speaker detection
- Description: Implement automatic speaker detection to identify and label different speakers in the transcript
- Notes: Research speaker diarization techniques compatible with WhisperKit or as post-processing step

**[Feature]** [Low] Database structure for searchable meeting notes (Phase 2)
- Description: Add optional SQLite database for advanced search and querying capabilities
- Notes: Build on top of folder export architecture
  - Primary data source: folder exports (canonical)
  - Database: derived index for performance (can be rebuilt)
  - Enables: full-text search, date ranges, speaker filtering, tag-based queries
  - Consider exposing via local HTTP API for other tools
- Prerequisites: Folder export integration (above) must be complete first
- Related: SQLite, FileOutputService.swift, potential future MCP server

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
- See "Capture and publish app screenshots" in In Progress section

**[Enhancement]** [Low] Make reprocessing chunk size configurable in preferences
- Description: Add preference setting to allow users to configure chunk size specifically for reprocessing transcripts
- Notes: Currently reprocessing uses the same audio chunk duration setting as live recording. Consider whether to use the same setting or add a separate "reprocessing chunk duration" preference
- May want different chunk sizes for reprocessing vs live recording (e.g., larger chunks for better accuracy when latency doesn't matter)
- Related: PreferencesView.swift, PreferencesManager.swift, RecordingDetailView.swift, CompletedMeetingWindow.swift

### Bugs

*No items - All high-priority bugs fixed in v0.1.2*

### Refactoring

**[Refactor]** [Medium] Update agent instructions for test execution
- Description: Clarify in AGENTS.md how agents should run tests, capture results, and extract information efficiently
- Notes: Should cover:
  - Running tests with output capture (tee vs direct output)
  - Extracting specific test results (grep patterns for failures, specific tests)
  - Best practices for test iteration (avoid re-running just to see different output)
  - Understanding XCTest output format
- Would improve agent efficiency and reduce unnecessary test runs
- Related: AGENTS.md, MuesliTests/, test execution workflows
- Status: Partial - commands/run_tests.md created

**[Refactor]** [Low] Create commands/ directory with common agent commands
- Description: Add commands/ directory containing commonly used command scripts for agents
- Notes: Could include:
  - build.sh - Standard build command with timestamp
  - test.sh - Run tests with proper output capture
  - clean-build.sh - Clean and rebuild
  - launch.sh - Kill and relaunch app
  - full-cycle.sh - Build, test, launch in one command
- Makes it easier for agents to execute common workflows
- Related: AGENTS.md, scripts/
- Status: Started - commands/run_tests.md exists

**[Refactor]** [Medium] Mutation testing with Muter
- Description: Implement mutation testing to measure test quality, not just coverage
- Notes: Muter introduces small mutations to code and verifies tests catch them
- Helps identify weak tests that have high coverage but don't actually validate behavior
- Related: https://github.com/muter-mutation-testing/muter
- Integration: Could run as part of CI or as manual quality check before releases

**[Refactor]** [Low] Coverage-guided test generation using AI tools
- Description: Explore AI-powered tools to automatically generate tests for uncovered code paths
- Notes: Could use LLM-based test generation tools to identify gaps and suggest test cases
- Should complement manual testing, not replace it
- Focus on edge cases and error paths that are easy to miss
- Related: Testing infrastructure, CI/CD workflows

**[Refactor]** [Low] Enforce SwiftLint in CI
- Description: Fix all existing lint violations and remove continue-on-error from CI
- Notes: Currently advisory only. Need baseline cleanup first before enforcing strict mode.
- Related: .swiftlint.yml, .github/workflows/ci.yml
- Status: Configuration complete in v0.1.2, enforcement pending

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
- Branch: release/v0.1.2-polish

**[Enhancement]** Add live transcript refinement
- Completed: Infrastructure added for real-time refinement during recording
- Files: TranscriptionCoordinator.swift, RefinementCoordinator.swift
- Notes: Backend support complete, UI activation to come in future release
- Branch: release/v0.1.2-polish

**[Enhancement]** Add copy transcript to clipboard button
- Completed: Copy button with plain text and Markdown format options
- Files: ClipboardHelper.swift, RecordingDetailView.swift, CompletedMeetingWindow.swift
- Branch: release/v0.1.2-polish

**[Enhancement]** Improve DMG installer appearance
- Completed: Custom SVG background with app icon, arrow, installation instructions
- Files: assets/dmg-background.svg, scripts/create-dmg-modern.sh
- Branch: release/v0.1.2-polish

**[Bug]** Onboarding instant permission updates
- Completed: Real-time monitoring with distributed notifications + polling fallback
- Files: PermissionManager.swift, OnboardingView.swift
- Branch: release/v0.1.2-polish

**[Bug]** Handle blank audio and random snippets
- Completed: Hallucination filter added to TranscriptProcessor
- Files: TranscriptProcessor.swift
- Filters: "thank you", "subscribe", repetitive text, common filler words
- Branch: release/v0.1.2-polish

**[Refactor]** UI Testing Framework
- Completed: XCUITest suite for screenshot capture
- Files: MuesliUITests/ directory with test files and helpers
- Supports: Light/dark modes, mocked permissions, fixture data
- Branch: release/v0.1.2-polish

**[Refactor]** SwiftLint Configuration
- Completed: Code quality standards configured
- File: .swiftlint.yml
- Status: Advisory mode (will enforce in future release)
- Branch: release/v0.1.2-polish

**[Refactor]** Worktree isolation configuration
- Completed: Added .worktree-config.json template and documentation
- Files: .worktree-config.json.template, AGENTS.md, spec/git_workflow.md, scripts/configure-worktree.sh
- Notes: Optional per-branch configuration for parallel development
- Branch: release/v0.1.2-polish

**[Feature]** Folder-backed integration for external tools (MCP-style) - Phase 1
- Completed: Automatic export of transcripts and metadata to structured folder for external tool access
- Files: ExportService.swift, ExportServiceProtocol (in ServiceProtocols.swift), ExportServiceTests.swift, MockExportService.swift
- Integration: RecordingController, PreferencesManager, PreferencesView, TranscriptionCoordinator, RefinementCoordinator
- Features:
  - Automatic export after recording completes (when enabled in preferences)
  - Re-export on transcript reprocessing or refinement
  - Manual "Export All Now" button in preferences
  - Structured folder hierarchy: ~/Library/Application Support/Muesli/Exports/
  - Global manifest.json for indexing all meetings
  - Per-meeting metadata.json with structured data
  - Markdown transcripts copied for human readability
  - Version marker file for format compatibility
- Architecture:
  - ExportService handles folder creation, file copying, JSON generation
  - Callbacks in TranscriptionCoordinator and RefinementCoordinator for re-export
  - Preferences for enable/disable and custom export directory
  - Graceful error handling (export failures don't affect recording)
- Testing: Comprehensive test suite with ≥70% coverage
- Date: 2026-01-18
- Phase 2 (Future): Local HTTP API, SQLite index, incremental sync, MCP server implementation

