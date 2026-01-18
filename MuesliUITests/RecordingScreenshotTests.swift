import XCTest

/// UI tests for capturing recording state screenshots
final class RecordingScreenshotTests: XCTestCase {
    
    var app: XCUIApplication!
    
    override func setUpWithError() throws {
        continueAfterFailure = false
    }
    
    // MARK: - Light Mode Screenshots
    
    func testRecording_IdleState_Light() throws {
        app = UITestHelpers.launchApp(appearance: .light)
        
        // Wait for main window
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(UITestHelpers.waitForElement(mainWindow, timeout: 3))
        
        // Look for start recording button or idle state
        let startButton = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'start' OR label CONTAINS[c] 'record'")).firstMatch
        if UITestHelpers.waitForElement(startButton, timeout: 2) {
            UITestHelpers.takeScreenshot(named: "recording-idle-state", appearance: .light, in: self)
        }
    }
    
    func testRecording_ActiveRecording_Light() throws {
        app = UITestHelpers.launchApp(
            useFixtures: true, // Use fixtures to simulate active recording
            appearance: .light
        )
        
        // Wait for main window
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(UITestHelpers.waitForElement(mainWindow, timeout: 3))
        
        // Look for recording indicator (red dot or "Recording" text)
        let recordingIndicator = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'recording'")).firstMatch
        if UITestHelpers.waitForElement(recordingIndicator, timeout: 2) {
            // Wait a moment for UI to stabilize
            sleep(1)
            UITestHelpers.takeScreenshot(named: "recording-active", appearance: .light, in: self)
        }
    }
    
    func testRecording_LiveTranscript_Light() throws {
        app = UITestHelpers.launchApp(
            useFixtures: true,
            appearance: .light
        )
        
        // Wait for transcript view to appear
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(UITestHelpers.waitForElement(mainWindow, timeout: 3))
        
        // Look for transcript content
        let transcriptView = app.scrollViews.firstMatch
        if UITestHelpers.waitForElement(transcriptView, timeout: 2) {
            // Wait for some transcript content to appear
            sleep(2)
            UITestHelpers.takeScreenshot(named: "recording-live-transcript", appearance: .light, in: self)
        }
    }
    
    // MARK: - Dark Mode Screenshots
    
    func testRecording_IdleState_Dark() throws {
        app = UITestHelpers.launchApp(appearance: .dark)
        
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(UITestHelpers.waitForElement(mainWindow, timeout: 3))
        
        let startButton = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'start' OR label CONTAINS[c] 'record'")).firstMatch
        if UITestHelpers.waitForElement(startButton, timeout: 2) {
            UITestHelpers.takeScreenshot(named: "recording-idle-state", appearance: .dark, in: self)
        }
    }
    
    func testRecording_ActiveRecording_Dark() throws {
        app = UITestHelpers.launchApp(
            useFixtures: true,
            appearance: .dark
        )
        
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(UITestHelpers.waitForElement(mainWindow, timeout: 3))
        
        let recordingIndicator = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'recording'")).firstMatch
        if UITestHelpers.waitForElement(recordingIndicator, timeout: 2) {
            sleep(1)
            UITestHelpers.takeScreenshot(named: "recording-active", appearance: .dark, in: self)
        }
    }
}
