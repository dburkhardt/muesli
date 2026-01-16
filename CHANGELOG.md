# Changelog

All notable changes to Muesli will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned
- LLM-powered transcript refinement (speaker identification, formatting)
- Support for additional transcription models
- Advanced search and filtering in meeting history
- Export to additional formats (PDF, DOCX)
- Keyboard shortcuts for common actions

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
- **Model management**: Download and switch between Whisper models (tiny, base, small, medium)
- **Onboarding wizard**: Guided setup for permissions and model download
- **Auto-updates**: Built-in update checker for new releases

### Technical
- Swift 6 with strict concurrency checking
- SwiftUI with `@Observable` architecture
- Native macOS 14+ (Sonoma and later)
- Apple Silicon optimized (M1/M2/M3)
- Minimal dependencies (WhisperKit only)
- Complete test coverage for core components

### Known Limitations
- Requires macOS 14.0 (Sonoma) or later
- Apple Silicon only (Intel Macs not supported)
- App is unsigned (requires Gatekeeper bypass)
- No speaker diarization in v0.1.0 (planned for future release)
- English language models only (multilingual support planned)

[unreleased]: https://github.com/dburkhardt/muesli/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/dburkhardt/muesli/releases/tag/v0.1.0
