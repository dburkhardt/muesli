# MuesliUITests Setup Instructions

The UI test files have been created in the `MuesliUITests/` directory. To complete the setup:

## Add UI Test Target in Xcode

1. Open `Muesli.xcodeproj` in Xcode
2. Select the project in the navigator
3. Click the "+" button at the bottom of the targets list
4. Choose "UI Testing Bundle"
5. Name it "MuesliUITests"
6. Set the target to test: "Muesli"
7. Click "Finish"

## Add Test Files to Target

1. In the Project Navigator, select all files in `MuesliUITests/`:
   - `UITestHelpers.swift`
   - `OnboardingScreenshotTests.swift`
   - `RecordingScreenshotTests.swift`
   - `HistoryScreenshotTests.swift`
   - `PreferencesScreenshotTests.swift`
   - `PopoutWindowScreenshotTests.swift`

2. In the File Inspector (right sidebar), check the "MuesliUITests" target membership

## Configure Test Scheme

1. Edit the "Muesli" scheme (Product → Scheme → Edit Scheme)
2. Select "Test" in the sidebar
3. Add "MuesliUITests" to the list of test targets
4. Ensure "MuesliTests" is also included

## Run Tests

```bash
xcodebuild test -project Muesli.xcodeproj -scheme Muesli -destination 'platform=macOS' -only-testing:MuesliUITests
```

Screenshots will be saved to test results and can be exported.

## Alternative: Command Line Setup

If you prefer, you can run:

```bash
cd /Users/dburkhardt/git-repos/muesli
# This would require a more complex pbxproj manipulation
# For now, manual Xcode setup is recommended
```
