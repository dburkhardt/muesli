# Changelog

All notable changes to Muesli will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned
- Support for additional transcription models
- Advanced search and filtering in meeting history
- Export to additional formats (PDF, DOCX)
- Keyboard shortcuts for common actions

## [0.6.0] - TBD

### Added
- **LLM Transcript Refinement**: Polish transcripts using on-device MLX LLM models (Llama 3.2 variants)
- **LLM Onboarding Step**: Fifth onboarding screen for optional LLM model download
- **Code Signing & Notarization**: App is now signed with Developer ID and notarized by Apple in the release workflow
- **macOS 26 SDK**: Release builds target macOS 26 (Tahoe) with Liquid Glass button styling
- **Expanded Model Support**: Supported WhisperKit models updated to Small, Medium, Large v3, and Large v3 Turbo (tiny/base removed)

### Changed
- Deployment target raised to macOS 26.0
- `LSUIElement` set to `false` — app appears in the Dock (was previously agent-only)
- Whisper model default changed from `base` to `small` in onboarding

## [0.1.2] - TBD

### Added
- **WebRTC AEC3 Echo Cancellation**: Replaced NLMS with WebRTC AEC3 as the default echo cancellation implementation
  - 2-3x better echo suppression (25-35 dB ERLE vs 10-15 dB)
  - Built-in double-talk detection and non-linear processing
  - Hybrid synchronization architecture handles 250-350ms mic-first timing offset
  - NLMS preserved as fallback option (accessible via hidden preference)
- **UI Testing Framework**: Comprehensive XCUITest suite for capturing screenshots of all major screens
- **Screenshot Capture**: Automated screenshot generation for website and documentation (light/dark modes)
- **Copy Transcript**: Added clipboard copy functionality with plain text and Markdown format options
- **Configurable Audio Chunking**: User-adjustable chunk duration (2-10 seconds) for transcription quality vs. latency tradeoff
- **Live Refinement Infrastructure**: Backend support for real-time transcript refinement during recording (hidden feature for v0.1.2)
- **Custom DMG Background**: Professional installer design with app icon, arrow, and installation instructions
- **Hallucination Filtering**: Improved filtering of common Whisper hallucinations on silence/blank audio

### Improved
- **Instant Permission Updates**: Onboarding now instantly reflects permission changes without requiring app restart
- **Real-time Monitoring**: Added distributed notification observers for system-level permission changes
- **Permission Polling**: Automatic fallback polling (1-second interval) for permission status
- **DMG Creation**: Enhanced scripts with automatic SVG-to-PNG conversion and fallback options
- **UI Testing Support**: Launch arguments for mocking permissions, models, and fixture data

### Fixed
- **Onboarding UX**: Permission screens now update immediately when user grants access in System Settings
- **Permission Monitoring**: Uses both notification observers and polling for reliable instant updates

### Technical
- Added `PermissionManager.startMonitoringPermissions()` for real-time permission tracking
- Added `TranscriptionCoordinator` live refinement queue (max depth: 5, background QoS)
- UI test helpers with mocking infrastructure (`-UITestingSkipOnboarding`, `-UITestingMockPermissions`)
- SwiftLint configuration for code quality standards
- Worktree isolation documentation and templates for parallel branch development

## [0.1.0] - 2026-01-16

### Added
- **Real-time transcription**: On-device speech-to-text powered by WhisperKit
- **System audio capture**: Record audio from meeting apps (Zoom, Teams, Google Meet) using ScreenCaptureKit
- **Microphone capture**: Simultaneous recording of your microphone input with device selection
- **Meeting history**: Browse, search, and replay past meeting transcripts
- **Markdown export**: Save transcripts as clean Markdown files with timestamps
- **On-device processing**: All transcription happens locally - no cloud services, complete privacy
- **Menu bar interface**: Unobtrusive menu bar app with quick access to recordings
- **Meeting app detection**: Automatically detects when common meeting apps are running
- **Model management**: Download and switch between Whisper models (small, medium, large-v3, large-v3-turbo)
- **Onboarding wizard**: Guided setup for permissions and model download
- **Auto-updates**: Built-in update checker for new releases

### Technical
- Swift 6 with strict concurrency checking
- SwiftUI with `@Observable` architecture
- Native macOS 26+
- Apple Silicon optimized (M1/M2/M3)
- Minimal dependencies (WhisperKit only)
- Complete test coverage for core components

### Known Limitations
- Requires macOS 26 or later
- Apple Silicon only (Intel Macs not supported)
- App is unsigned (requires Gatekeeper bypass)
- No speaker diarization in v0.1.0 (planned for future release)
- English language models only (multilingual support planned)

[unreleased]: https://github.com/dburkhardt/muesli/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/dburkhardt/muesli/compare/v0.1.2...v0.6.0
[0.1.2]: https://github.com/dburkhardt/muesli/compare/v0.1.0...v0.1.2
[0.1.0]: https://github.com/dburkhardt/muesli/releases/tag/v0.1.0
