import XCTest

/// UI tests for capturing popout window screenshots
final class PopoutWindowScreenshotTests: XCTestCase {
    
    var app: XCUIApplication!
    
    override func setUpWithError() throws {
        continueAfterFailure = false
    }
    
    // MARK: - Light Mode Screenshots
    
    func testPopout_CompletedMeeting_Light() throws {
        app = UITestHelpers.launchApp(
            useFixtures: true, // Need fixture data for completed meetings
            appearance: .light
        )
        
        // Wait for main window
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(UITestHelpers.waitForElement(mainWindow, timeout: 3))
        
        // Double-click on first meeting to open popout
        let firstMeetingRow = app.tables.cells.firstMatch
        if UITestHelpers.waitForElement(firstMeetingRow, timeout: 2) {
            firstMeetingRow.doubleClick()
            
            // Wait for popout window to appear
            sleep(1)
            
            // Check if we have a second window (the popout)
            if app.windows.count > 1 {
                // Focus on the popout window
                let popoutWindow = app.windows.element(boundBy: 1)
                if popoutWindow.exists {
                    UITestHelpers.takeScreenshot(named: "popout-completed-meeting", appearance: .light, in: self)
                }
            }
        }
    }
    
    func testPopout_TranscriptView_Light() throws {
        app = UITestHelpers.launchApp(
            useFixtures: true,
            appearance: .light
        )
        
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(UITestHelpers.waitForElement(mainWindow, timeout: 3))
        
        let firstMeetingRow = app.tables.cells.firstMatch
        if UITestHelpers.waitForElement(firstMeetingRow, timeout: 2) {
            firstMeetingRow.doubleClick()
            sleep(1)
            
            if app.windows.count > 1 {
                // Scroll down in transcript to show content
                let scrollView = app.scrollViews.firstMatch
                if scrollView.exists {
                    // Scroll a bit to show transcript content
                    scrollView.swipeUp()
                    sleep(0.5)
                    
                    UITestHelpers.takeScreenshot(named: "popout-transcript-view", appearance: .light, in: self)
                }
            }
        }
    }
    
    // MARK: - Dark Mode Screenshots
    
    func testPopout_CompletedMeeting_Dark() throws {
        app = UITestHelpers.launchApp(
            useFixtures: true,
            appearance: .dark
        )
        
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(UITestHelpers.waitForElement(mainWindow, timeout: 3))
        
        let firstMeetingRow = app.tables.cells.firstMatch
        if UITestHelpers.waitForElement(firstMeetingRow, timeout: 2) {
            firstMeetingRow.doubleClick()
            sleep(1)
            
            if app.windows.count > 1 {
                let popoutWindow = app.windows.element(boundBy: 1)
                if popoutWindow.exists {
                    UITestHelpers.takeScreenshot(named: "popout-completed-meeting", appearance: .dark, in: self)
                }
            }
        }
    }
}
