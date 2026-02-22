# Export System Architecture

This document describes Muesli's export system for making meeting transcripts and metadata available to external tools (MCP servers, IDE extensions, etc.).

## Overview

The export system automatically exports meeting transcripts and metadata to a structured folder hierarchy that external tools can access as a read-only knowledge source. This provides loose coupling without requiring a local API server.

## Design Goals

1. **Loose Coupling**: External tools treat Muesli as a read-only knowledge source
2. **Transparency**: Users can inspect exported data directly in the file system
3. **Simplicity**: Folder-based approach avoids complex API implementation
4. **Durability**: Folder structure serves as stable contract between apps
5. **Non-Intrusive**: Export failures never affect core recording functionality

## Architecture

### Components

```
┌─────────────────────────────────────────────────────────────┐
│                     MuesliViewModel                          │
│  ┌────────────────────────────────────────────────────────┐ │
│  │         PreferencesManager                             │ │
│  │  - exportEnabled: Bool                                 │ │
│  │  - exportDirectory: URL                                │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                               │
│  ┌────────────────────────────────────────────────────────┐ │
│  │         ExportService                                  │ │
│  │  - exportMeeting(_:)                                   │ │
│  │  - exportAllMeetings(_:)                               │ │
│  │  - generateManifest(for:)                              │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                             │
                             ▼
            ┌────────────────────────────────┐
            │   Export Directory             │
            │   ~/Library/Application        │
            │   Support/Muesli/Exports/      │
            └────────────────────────────────┘
                             │
                             ▼
            ┌────────────────────────────────┐
            │   External Tools               │
            │   (MCP Servers, IDEs, etc.)    │
            │   READ-ONLY ACCESS             │
            └────────────────────────────────┘
```

### Key Components

#### ExportService

**Location**: `Muesli/Services/ExportService.swift`
**Conforms to**: `ExportServiceProtocol` (defined in `Muesli/Protocols/ServiceProtocols.swift`)

**Responsibilities**:
- Create and manage export directory structure
- Copy transcript files to export location
- Generate JSON metadata files
- Update global manifest
- Handle errors gracefully (log but don't throw to UI)

**Key Methods**:
```swift
func exportMeeting(_ meeting: MeetingHistoryItem) async throws
func exportAllMeetings(_ meetings: [MeetingHistoryItem]) async throws -> Int
func generateManifest(for meetings: [MeetingHistoryItem]) throws
func createVersionMarker() throws
func setExportDirectory(_ url: URL)
func resetToDefaultExportDirectory()

var onWarning: ((String, String) -> Void)?
// Callback invoked when a non-fatal warning occurs during export
// (e.g., partial write, fallback path used). Parameters are (title, message).
```

#### PreferencesManager

**Export-Related Properties**:
```swift
var exportEnabled: Bool  // Default: true
var exportDirectory: URL // Default: ~/Library/Application Support/Muesli/Exports/
```

**Methods**:
```swift
func resetExportDirectory()
// Internally calls exportService.resetToDefaultExportDirectory()
```

#### Integration Points

1. **RecordingController**: Exports after recording completes
2. **TranscriptionCoordinator**: Re-exports when transcripts are reprocessed
3. **RefinementCoordinator**: Re-exports when transcripts are refined
4. **MuesliViewModel**: Provides UI delegation and manual export trigger

## Export Directory Structure

```
~/Library/Application Support/Muesli/Exports/
├── .muesli-export              # Version marker file
├── manifest.json               # Global index of all meetings
└── meetings/                   # Per-meeting exports
    ├── 2026-01-15_14-30_[UUID]/
    │   ├── transcript.md       # Human-readable transcript
    │   ├── ai_summary.md       # Optional AI notes summary
    │   └── metadata.json       # Machine-readable metadata
    ├── 2026-01-16_09-00_[UUID]/
    │   ├── transcript.md
    │   ├── ai_summary.md       # Optional
    │   └── metadata.json
    └── ...
```

### Version Marker (.muesli-export)

**Purpose**: Indicates export format version for external tool compatibility

**Format**: Plain text
```
version=1.0
format=markdown+json
```

### manifest.json

**Purpose**: Global index listing all exported meetings with summary metadata

**Schema**:
```json
{
  "version": "1.0",
  "generatedAt": "2026-01-18T10:30:00Z",
  "totalMeetings": 42,
  "meetings": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "title": "Team Standup",
      "date": "2026-01-15T14:30:00Z",
      "directory": "meetings/2026-01-15_14-30_550e8400-e29b-41d4-a716-446655440000",
      "hasAudio": true,
      "hasMicrophone": true,
      "duration": 2847.5,
      "wordCount": 1240,
      "hasAISummary": false,
      "isRefined": false,
      "segmentCount": 1
    }
  ]
}
```

**Field Definitions**:
- `version`: Export format version (always "1.0")
- `generatedAt`: ISO 8601 timestamp of manifest generation
- `totalMeetings`: Count of meetings in the manifest
- `meetings[]`: Array of meeting summaries
  - `id`: UUID of the meeting
  - `title`: Meeting title
  - `date`: ISO 8601 timestamp of recording start
  - `directory`: Relative path to meeting export folder
  - `hasAudio`: Whether system audio was captured
  - `hasMicrophone`: Whether microphone audio was captured
  - `duration`: Meeting duration in seconds (null if unavailable)
  - `wordCount`: Transcript word count (null if unavailable)
  - `hasAISummary`: Whether `ai_summary.md` exists for the meeting
  - `isRefined`: Whether transcript has been refined by LLM
  - `segmentCount`: Number of recording segments (1 = continuous, 2+ = resumed)

### metadata.json (per meeting)

**Purpose**: Detailed machine-readable metadata for a specific meeting

**Schema**:
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "title": "Team Standup",
  "date": "2026-01-15T14:30:00Z",
  "duration": 2847.5,
  "wordCount": 1240,
  "hasAudio": true,
  "hasMicrophone": true,
  "hasAISummary": false,
  "isRefined": false,
  "segmentCount": 1,
  "segments": [
    {
      "segmentNumber": 1,
      "startTime": "2026-01-15T14:30:00Z",
      "isRefined": false
    }
  ],
  "files": {
    "transcript": "transcript.md",
    "aiSummary": null,
    "audio": "../../Recordings/2026-01-15_14-30_550e8400-e29b-41d4-a716-446655440000/audio.caf",
    "microphone": "../../Recordings/2026-01-15_14-30_550e8400-e29b-41d4-a716-446655440000/microphone.caf"
  }
}
```

**Field Definitions**:
- `id`: UUID of the meeting
- `title`: Meeting title
- `date`: ISO 8601 timestamp of recording start
- `duration`: Meeting duration in seconds (null if unavailable)
- `wordCount`: Transcript word count (null if unavailable)
- `hasAudio`: Whether system audio was captured
- `hasMicrophone`: Whether microphone audio was captured
- `hasAISummary`: Whether AI notes are available
- `isRefined`: Whether transcript has been refined by LLM
- `segmentCount`: Number of recording segments
- `segments[]`: Array of segment metadata
  - `segmentNumber`: Segment index (1-based)
  - `startTime`: ISO 8601 timestamp when segment started
  - `isRefined`: Whether this segment has been refined
- `files`: File references (relative paths)
  - `transcript`: Path to transcript.md (relative to metadata.json)
  - `aiSummary`: Optional path to ai_summary.md (null if absent)
  - `audio`: Path to system audio file (null if not captured)
  - `microphone`: Path to microphone audio file (null if not captured)

### transcript.md (per meeting)

**Purpose**: Human-readable transcript in Markdown format

**Format**: Copy of the transcript from the Recordings directory

**Structure**:
```markdown
# Meeting Title
2026-01-15 14:30

## Transcript

**Me** _[0:15]_

Hello everyone, welcome to the meeting.

**Them** _[0:25]_

Thanks for having us!
```

## Export Triggers

### Automatic Export

Export occurs automatically when `exportEnabled` is `true` (default):

1. **After Recording Completes**
   - Triggered by: `RecordingController.stopRecordingAsync()`
   - Timing: After transcript is saved to Recordings directory
   - Method: `exportMeetingIfEnabled(directory:)`

2. **After Transcript Reprocessing**
   - Triggered by: `TranscriptionCoordinator.reprocessTranscript()`
   - Timing: After transcript is updated and saved
   - Method: `onMeetingUpdated` callback → `exportService.exportMeeting()`

3. **After Transcript Refinement**
   - Triggered by: `RefinementCoordinator.refineTranscriptAsync()`
   - Timing: After refined transcript is saved
   - Method: `onMeetingUpdated` callback → `exportService.exportMeeting()`

### Manual Export

Users can manually trigger export:

1. **Export All Meetings**
   - Location: Preferences → Output → "Export All Now" button
   - Method: `viewModel.exportAllMeetings()`
   - Behavior: Exports all discovered meetings and updates manifest

## Data Flow

### Recording Complete → Export

```
┌──────────────────────────────────────────────────────────┐
│ 1. User stops recording                                  │
└──────────────────┬───────────────────────────────────────┘
                   ▼
┌──────────────────────────────────────────────────────────┐
│ 2. RecordingController.stopRecordingAsync()              │
│    - Stops audio capture                                 │
│    - Saves audio files (audio.caf, microphone.caf)       │
│    - Saves transcript (transcript.md)                    │
└──────────────────┬───────────────────────────────────────┘
                   ▼
┌──────────────────────────────────────────────────────────┐
│ 3. RecordingController.exportMeetingIfEnabled()          │
│    - Check: preferencesManager.exportEnabled?            │
│    - If NO: return (skip export)                         │
│    - If YES: continue                                    │
└──────────────────┬───────────────────────────────────────┘
                   ▼
┌──────────────────────────────────────────────────────────┐
│ 4. Create MeetingHistoryItem from directory              │
│    - Parse folder name for date/UUID                     │
│    - Read transcript.md for title                        │
│    - Check for audio files                               │
└──────────────────┬───────────────────────────────────────┘
                   ▼
┌──────────────────────────────────────────────────────────┐
│ 5. ExportService.exportMeeting()                         │
│    - Ensure export directory exists                      │
│    - Create meeting export subdirectory                  │
│    - Copy transcript.md                                  │
│    - Generate metadata.json                              │
└──────────────────┬───────────────────────────────────────┘
                   ▼
┌──────────────────────────────────────────────────────────┐
│ 6. ExportService.generateManifest()                      │
│    - Load all meetings from MeetingHistoryService        │
│    - Generate manifest.json with all meetings            │
│    - Write manifest to export directory                  │
└──────────────────┬───────────────────────────────────────┘
                   ▼
┌──────────────────────────────────────────────────────────┐
│ 7. Export complete                                       │
│    - Log success                                         │
│    - Errors logged but don't affect UI                   │
└──────────────────────────────────────────────────────────┘
```

### Reprocessing → Re-export

```
┌──────────────────────────────────────────────────────────┐
│ 1. User reprocesses transcript with different model      │
└──────────────────┬───────────────────────────────────────┘
                   ▼
┌──────────────────────────────────────────────────────────┐
│ 2. TranscriptionCoordinator.reprocessTranscript()        │
│    - Transcribe audio with new model                     │
│    - Update meeting.transcriptBlocks                     │
│    - Save updated transcript to disk                     │
└──────────────────┬───────────────────────────────────────┘
                   ▼
┌──────────────────────────────────────────────────────────┐
│ 3. Call onMeetingUpdated callback                        │
│    - TranscriptionCoordinator.onMeetingUpdated?(meeting) │
└──────────────────┬───────────────────────────────────────┘
                   ▼
┌──────────────────────────────────────────────────────────┐
│ 4. ViewModel callback handler                            │
│    - Check: exportEnabled?                               │
│    - If YES: re-export meeting                           │
└──────────────────┬───────────────────────────────────────┘
                   ▼
┌──────────────────────────────────────────────────────────┐
│ 5. ExportService.exportMeeting()                         │
│    - Overwrite existing export with updated data         │
│    - Update manifest.json                                │
└──────────────────────────────────────────────────────────┘
```

## Error Handling

### Design Philosophy

**Export failures NEVER affect core functionality**. Recording, transcription, and file saving always proceed regardless of export status.

### Error Scenarios

1. **Export Directory Not Writable**
   - Behavior: Log error, skip export
   - User Impact: None (core files saved normally)
   - Recovery: User can manually export later or change directory

2. **Insufficient Disk Space**
   - Behavior: Log error, skip export
   - User Impact: None (original files in Recordings directory)
   - Recovery: Free disk space, manually re-export

3. **Missing Source Files**
   - Behavior: Log error, skip that meeting, continue with others
   - User Impact: Partial export (valid meetings still exported)
   - Recovery: Original files remain in Recordings directory

4. **JSON Encoding Failure**
   - Behavior: Log error with details, skip export
   - User Impact: None (core functionality unaffected)
   - Recovery: Report issue (likely code bug)

### Error Logging

All export errors are logged with `Logger` to the `ExportService` category:

```swift
logger.error("Failed to export meeting: \(error.localizedDescription)")
```

Logs can be viewed with Console.app filtering for:
- Subsystem: `com.muesli.app`
- Category: `ExportService`

## Testing

### Test Coverage

Test suite with **37 test cases** across 4 classes (all in `MuesliTests/`):

1. **ExportServiceTests** (22 tests, in `ExportServiceTests.swift`)
   - Directory creation and management
   - Single and bulk meeting export
   - Manifest generation
   - Edge cases (empty data, special characters, etc.)
   - File operations and error handling

2. **PreferencesManagerExportTests** (5 tests, in `ExportServiceTests.swift`)
   - Export preferences persistence
   - Default values
   - Configuration changes

3. **ExportIntegrationTests** (8 tests, in `ExportIntegrationTests.swift`)
   - ViewModel delegation
   - End-to-end export flow
   - Error handling
   - MockExportService behavior

4. **AppStorageKeysExportTests** (2 tests, in `ExportIntegrationTests.swift`)
   - Key definitions
   - Uniqueness validation

### Running Tests

```bash
# Run all export tests
xcodebuild test -scheme Muesli \
  -only-testing:MuesliTests/ExportServiceTests \
  -only-testing:MuesliTests/ExportIntegrationTests \
  -only-testing:MuesliTests/PreferencesManagerExportTests \
  -only-testing:MuesliTests/AppStorageKeysExportTests

# Run with coverage
./scripts/generate-coverage.sh
```

## User Interface

### Preferences → Output Tab

**Export Section**:

1. **Automatic Export Toggle**
   - Label: "Automatic Export"
   - Description: "Export transcripts to a structured folder for MCP servers and IDE extensions"
   - Default: ON
   - Effect: Enables/disables all automatic export triggers

2. **Export Location**
   - Display: Current export directory path
   - Button: "Choose..." to select custom directory
   - Button: "Reset to Default" to restore Application Support location

3. **Manual Export**
   - Button: "Export All Now"
   - Effect: Exports all meetings and shows count
   - State: Disabled when exportEnabled is OFF

## External Tool Integration

### For Tool Developers

#### Accessing Exports

```swift
// Default export location
let exportDir = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    .appendingPathComponent("Muesli/Exports")

// Check version marker
let markerPath = exportDir.appendingPathComponent(".muesli-export")
let version = try String(contentsOf: markerPath, encoding: .utf8)

// Load manifest
let manifestPath = exportDir.appendingPathComponent("manifest.json")
let manifestData = try Data(contentsOf: manifestPath)
let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)

// Access individual meetings
for meeting in manifest.meetings {
    let meetingDir = exportDir.appendingPathComponent(meeting.directory)
    let transcriptPath = meetingDir.appendingPathComponent("transcript.md")
    let metadataPath = meetingDir.appendingPathComponent("metadata.json")
    
    // Read transcript
    let transcript = try String(contentsOf: transcriptPath, encoding: .utf8)
    
    // Read metadata
    let metadataData = try Data(contentsOf: metadataPath)
    let metadata = try JSONDecoder().decode(MeetingMetadata.self, from: metadataData)
}
```

#### Best Practices

1. **Read-Only Access**: Never modify files in the export directory
2. **Version Check**: Always check `.muesli-export` marker for compatibility
3. **Incremental Updates**: Use `manifest.generatedAt` to detect changes
4. **File Watching**: Use `FSEvents` or `FileManager` to watch for new exports
5. **Error Handling**: Handle missing files gracefully (user may delete exports)
6. **Additive Schema Tolerance**: Treat unknown metadata fields as optional; `version=1.0` remains compatible with additive fields

### Use Cases

1. **MCP Servers**: Provide meeting context to AI assistants
2. **IDE Extensions**: Show meeting notes in code editor
3. **Search Tools**: Index transcripts for full-text search
4. **Analytics**: Extract insights, topics, action items
5. **Backup**: Sync exports to cloud storage
6. **Integration**: Connect with task managers, calendars, wikis

## Troubleshooting

### Export Not Working

**Symptoms**: Meetings recorded but not appearing in Exports folder

**Checks**:
1. Verify `exportEnabled` is true in Preferences → Output
2. Check Console.app for ExportService errors
3. Verify export directory is writable
4. Check available disk space

**Solutions**:
- Enable export in preferences
- Change export directory if current one is not writable
- Free disk space
- Manually export using "Export All Now" button

### Missing Meetings in Manifest

**Symptoms**: Some meetings not listed in manifest.json

**Causes**:
- Export was disabled when those meetings were recorded
- Export failed for those specific meetings
- Manual deletion of export folders

**Solutions**:
- Use "Export All Now" to re-export all meetings
- Check Console.app logs for specific errors
- Verify source files exist in Recordings directory

### Outdated Exports

**Symptoms**: Export doesn't reflect latest transcript changes

**Causes**:
- Export was disabled when transcript was updated
- Re-export callback failed

**Solutions**:
- Enable export in preferences
- Use "Export All Now" to refresh all exports
- Manually delete export directory and re-export

### External Tool Can't Read Exports

**Symptoms**: External tool reports errors reading export files

**Checks**:
1. Verify `.muesli-export` marker exists
2. Check version in marker matches tool expectations
3. Validate JSON files are well-formed
4. Verify file permissions allow reading

**Solutions**:
- Use "Export All Now" to regenerate exports
- Verify tool has read access to Application Support directory
- Check tool's version compatibility with export format 1.0

## Best Practices

### System Audio Permission Model
- The app uses a tap-probe at session start to determine system audio availability; there is no `CGPreflightScreenCaptureAccess()` preflight call.
- The result of the tap-probe is cached in `UserDefaults` so subsequent sessions can reference it without re-probing.

### Real-Time Audio Callback Constraints
- IOProc (real-time audio callbacks) must never perform heap allocation, Objective-C messaging, or lock acquisition.
- Violating these constraints causes priority inversion, audio glitches, or watchdog termination.

### WhisperKit Audio Format
- WhisperKit requires **16 kHz mono** audio input.
- Both system audio and microphone capture at **48 kHz**; always resample before passing buffers to WhisperKit (see `TranscriptionService.resampleToWhisperFormat()`).

### macOS Version Requirements
- `AudioHardwareCreateProcessTap` is available on **macOS 14.2+**.
- The app deployment target is **macOS 26.0**, which satisfies the 14.2+ API requirement.

## Future Enhancements (Phase 2)

Planned improvements for future releases:

1. **Local HTTP API**
   - REST endpoints for querying meetings
   - Search with filters (date range, speakers, keywords)
   - Incremental sync for external tools

2. **SQLite Index**
   - Derived index built from folder exports
   - Fast full-text search
   - Relationship queries

3. **MCP Server**
   - Native MCP protocol support
   - Streaming updates
   - Rich context provision to AI assistants

4. **Webhook Notifications**
   - Notify external tools on new/updated meetings
   - Configurable webhook URLs
   - Retry logic for failed notifications

5. **Incremental Sync**
   - Only export changed meetings
   - Change detection based on file modification times
   - Efficient for large meeting histories

## References

- **SPEC.md**: Overall product specification
- **AGENTS.md**: Development guidelines and commands
- **plans/todo.md**: Feature tracking and roadmap
- **Muesli/Services/ExportService.swift**: Implementation
- **MuesliTests/ExportServiceTests.swift**: Test suite
