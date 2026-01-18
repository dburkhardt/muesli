# SwiftLint Violations - Remaining Work Plan

## Current Status (as of 2026-01-18)

### Progress Summary
- **Initial violations**: 504 (50 errors, 454 warnings)
- **Current violations**: 379 (17 errors, 362 warnings)
- **Reduction**: 125 violations fixed (25% improvement)
- **Build status**: ✅ Passing
- **Test status**: ✅ All tests passing

### Completed Work
- ✅ Phase 1: Critical Errors (identifier names, empty count, line length >150, tuple violations)
- ✅ Phase 2: Logging Infrastructure (partial - 39/86 print() statements replaced)

## Remaining Work

### Phase 2 (Continued): Complete Logging Migration

**Goal**: Replace remaining 47 print() statements with Logger

**Remaining print() violations by file:**

Test Files (Lower Priority):
- `MuesliTests/AudioCaptureServiceTests.swift` - Multiple print statements in test setup/teardown
- `MuesliTests/MuesliViewModelTests.swift` - Test diagnostic prints
- `MuesliTests/TranscriptionServiceTests.swift` - Test logging
- Other test files

Production Files (Higher Priority):
- Check for any remaining prints in Services/ that weren't caught

**Action Items:**
1. Add logger to remaining test files (consider if test logs are needed or can be removed)
2. Verify all production code uses Logger instead of print()
3. Run `swiftlint lint --quiet 2>&1 | grep "no_print"` to verify zero violations

**Estimated Time**: 1-2 hours

---

### Phase 3: Fix Formatting Violations

**Goal**: Fix ~280 remaining formatting warnings

**Categories:**

#### 3.1 Line Length Warnings (120-150 chars) - ~75 violations
Files with most violations:
- `Services/TranscriptionService.swift`
- `Services/FileOutputService.swift`
- `Views/RecordingDetailView.swift`
- `Controllers/RecordingController.swift`

**Strategy:**
- Break long method chains across multiple lines
- Split long string literals with continuation
- Break long parameter lists into multiple lines
- Use local variables for complex expressions

#### 3.2 Vertical Whitespace - ~70 violations
**Issues:**
- Double blank lines (should be single)
- Blank lines after opening braces `{`
- Blank lines before closing braces `}`

**Strategy:**
- Run find/replace to remove double newlines: `\n\n\n` → `\n\n`
- Manually fix blank lines adjacent to braces

#### 3.3 Sorted Imports - ~30 violations
**Files needing attention:**
- `RecordingController.swift`
- Various view files

**Strategy:**
- Sort imports alphabetically within each file
- Order: Foundation → System frameworks → Third-party → Project

#### 3.4 Spacing Issues - ~68 violations
**Types:**
- Colon spacing (38): `var x:Int` → `var x: Int`
- Comma spacing (30): `func f(a,b)` → `func f(a, b)`

**Strategy:**
- Most are auto-fixable with `swiftlint --fix`
- Manual fixes where auto-fix doesn't work

**Estimated Time**: 2-3 hours

---

### Phase 4: Code Quality Improvements

**Goal**: Improve code structure and readability

#### 4.1 Multiple Closures with Trailing Closure - 27 violations

**Problem**: SwiftUI API violations
```swift
// Current (violates rule)
Button("Label") {
    action()
} label: {
    customLabel
}

// Fixed
Button(action: {
    action()
}, label: {
    customLabel
})
```

**Files:**
- `Views/MeetingHistorySidebar.swift`
- `Views/StartRecordingSheet.swift`
- `Views/AboutView.swift`
- `Views/CompletedMeetingWindow.swift`

#### 4.2 Function Body Length - 16 violations

**Functions 60-100 lines that need refactoring:**
- `RecordingController.swift` - Extract helper methods
- `ModelManagementView.swift` - Extract view builders
- `RecordingDetailView.swift` - Break into smaller functions

**Strategy:**
- Extract repeated logic into private helper methods
- Break complex functions into smaller, focused functions
- Consider extracting to separate extensions for related functionality

#### 4.3 Identifier Naming - 9 violations

**Issues:**
- Single-letter variables: `f` → `file` or `folder`
- Non-descriptive names in loops

**Files:**
- `Views/CompletedMeetingWindow.swift`

#### 4.4 Function Parameter Count - 2 violations

**Problem**: Functions with 6-7 parameters in `RecordingController.swift`

**Strategy:**
- Introduce parameter structs or configuration objects
- Group related parameters into a single type

#### 4.5 Miscellaneous - 12 violations

**Types:**
- Large tuple violations (3): Replace with structs
- Prefer for-where violations (1): Use `for x in y where condition`
- Trailing comma violations (4): Add trailing commas to multi-line arrays/dicts

**Estimated Time**: 3-4 hours

---

### Phase 5: File/Type Length Refactoring

**Goal**: Fix remaining 17 errors (all file/type body length violations)

#### Critical Files Requiring Refactoring:

**5.1 Test Files (Lower Priority)**
- `MuesliTests/AudioCaptureServiceTests.swift` (1383 lines)
  - **Strategy**: Split into multiple test files by feature area
  - `AudioCaptureServiceBasicTests.swift`
  - `AudioCaptureServiceBufferTests.swift`
  - `AudioCaptureServiceErrorTests.swift`

- `MuesliTests/MuesliViewModelTests.swift` (2426 lines, 1365 line body)
  - **Strategy**: Split by test category
  - `MuesliViewModelRecordingTests.swift`
  - `MuesliViewModelHistoryTests.swift`
  - `MuesliViewModelPermissionTests.swift`

**5.2 Production Files (Higher Priority)**
- `Controllers/RecordingController.swift` (908 lines, 610 line body)
  - **Strategy**: Extract to extensions
  - `RecordingController+AudioCallbacks.swift` - Audio buffer handling
  - `RecordingController+Transcription.swift` - Transcription coordination
  - `RecordingController+ErrorHandling.swift` - Error handling methods

- `ViewModels/MuesliViewModel.swift` (845 lines)
  - **Strategy**: Already well-separated with coordinators, just needs minor trimming
  - Extract some utility methods to extensions

- `Views/OnboardingView.swift` (868 lines, 659 line body)
  - **Strategy**: Extract screens to separate files
  - `OnboardingWelcomeScreen.swift`
  - `OnboardingPermissionsScreen.swift`
  - `OnboardingModelScreen.swift`
  - `OnboardingCompletionScreen.swift`

- `Views/RecordingDetailView.swift` (963 lines, 704 line body)
  - **Strategy**: Extract components to separate files
  - `RecordingDetailHeader.swift`
  - `RecordingDetailToolbar.swift`
  - `RecordingDetailTranscript.swift`

- `Services/TranscriptionService.swift` (905 lines)
  - **Strategy**: Extract to extensions
  - `TranscriptionService+PostProcessing.swift`
  - `TranscriptionService+AudioResampling.swift`

**Estimated Time**: 4-5 hours

---

### Phase 6: Enable Strict CI

**Goal**: Remove `continue-on-error: true` from CI and enforce zero violations

#### 6.1 Final Verification

Before enabling strict mode:
1. Run full SwiftLint check: `swiftlint lint --strict`
2. Verify exit code is 0
3. Run all tests: `xcodebuild test -project Muesli.xcodeproj -scheme Muesli`
4. Verify clean build with no warnings

#### 6.2 Update CI Configuration

File: `.github/workflows/ci.yml`

**Change:**
```yaml
# Line 149 - REMOVE these lines:
continue-on-error: true  # Advisory only - violations reported but don't block merges
                         # TODO: Remove after baseline cleanup (track in TODO.md)
```

#### 6.3 Update Documentation

Update `plans/TODO.md`:
- Remove SwiftLint cleanup task
- Add note about maintaining zero violations going forward

**Estimated Time**: 30 minutes

---

## Total Remaining Effort

| Phase | Description | Estimated Time |
|-------|-------------|----------------|
| 2 (cont.) | Complete logging migration | 1-2 hours |
| 3 | Fix formatting violations | 2-3 hours |
| 4 | Code quality improvements | 3-4 hours |
| 5 | File/type length refactoring | 4-5 hours |
| 6 | Enable strict CI | 0.5 hours |
| **Total** | | **11-14.5 hours** |

## Implementation Strategy

### Recommended Order:

1. **Quick Wins First** (2-3 hours):
   - Complete logging migration (Phase 2)
   - Auto-fix formatting with `swiftlint --fix` (Phase 3 partial)
   - Fix manual spacing issues (Phase 3)

2. **Structural Improvements** (6-8 hours):
   - File/type length refactoring (Phase 5) - Do this before Phase 4
   - Once files are smaller, Phase 4 improvements will be easier
   - Fix closure syntax violations (Phase 4.1)
   - Refactor long functions (Phase 4.2)

3. **Final Cleanup** (2-3 hours):
   - Fix remaining identifier names (Phase 4.3)
   - Fix parameter counts (Phase 4.4)
   - Fix miscellaneous violations (Phase 4.5)

4. **Verification & Enable CI** (1 hour):
   - Run full test suite
   - Verify zero violations
   - Enable strict mode in CI (Phase 6)

### Commit Strategy:

Make incremental commits after each major change:
- "refactor: Split RecordingController into extensions"
- "style: Fix line length warnings in TranscriptionService"
- "refactor: Extract OnboardingView screens to separate files"
- "style: Fix closure syntax violations"
- "ci: Enable strict SwiftLint enforcement"

### Testing Strategy:

After each phase:
1. Build: `xcodebuild -project Muesli.xcodeproj -scheme Muesli build`
2. Test: `xcodebuild test -project Muesli.xcodeproj -scheme Muesli`
3. Lint: `swiftlint lint --quiet | head -50`
4. Launch app and verify basic functionality

## Success Criteria

- ✅ Zero SwiftLint violations (`swiftlint lint --strict` exits with code 0)
- ✅ All 162+ tests pass
- ✅ Clean build with no warnings
- ✅ CI enforces SwiftLint (`continue-on-error` removed)
- ✅ All production code uses Logger instead of print()
- ✅ No files exceed 800 lines
- ✅ No type bodies exceed 500 lines
- ✅ No lines exceed 150 characters

## Notes

- **Preserve behavior**: All changes should be refactoring/formatting only
- **Keep tests passing**: Run tests after each major change
- **Incremental commits**: Enable easy rollback if needed
- **Review changes**: Keep PRs focused and reviewable

## Reference

- SwiftLint config: `.swiftlint.yml`
- CI workflow: `.github/workflows/ci.yml` (line 149)
- Project standards: `AGENTS.md`
- Current violations: Run `swiftlint lint --quiet`
