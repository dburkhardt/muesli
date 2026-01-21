import XCTest

/// UI tests for capturing meeting history screenshots
final class HistoryScreenshotTests: XCTestCase {
    
    var app: XCUIApplication!
    
    override func setUpWithError() throws {
        continueAfterFailure = false
    }
    
    // MARK: - Light Mode Screenshots
    
    func testHistory_EmptyState_Light() throws {
        app = UITestHelpers.launchApp(appearance: .light)
        
        // Wait for main window
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(UITestHelpers.waitForElement(mainWindow, timeout: 3))
        
        // Look for empty state message
        let emptyStateText = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'no recordings' OR label CONTAINS[c] 'no meetings'")).firstMatch
        if UITestHelpers.waitForElement(emptyStateText, timeout: 2) {
            UITestHelpers.takeScreenshot(named: "history-empty-state", appearance: .light, in: self)
        }
    }
    
    func testHistory_ListView_Light() throws {
        app = UITestHelpers.launchApp(
            useFixtures: true, // Use fixtures to show meeting history
            appearance: .light
        )
        
        // Wait for main window
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(UITestHelpers.waitForElement(mainWindow, timeout: 3))
        
        // Wait for history list to appear
        sleep(1)
        UITestHelpers.takeScreenshot(named: "history-list-view", appearance: .light, in: self)
    }
    
    func testHistory_SplitView_Light() throws {
        app = UITestHelpers.launchApp(
            useFixtures: true,
            appearance: .light
        )
        
        // Wait for main window
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(UITestHelpers.waitForElement(mainWindow, timeout: 3))
        
        // Try to click on a meeting item to show split view
        let firstMeetingRow = app.tables.cells.firstMatch
        if UITestHelpers.waitForElement(firstMeetingRow, timeout: 2) {
            firstMeetingRow.click()
            
            // Wait for split view to appear
            sleep(1)
            UITestHelpers.takeScreenshot(named: "history-split-view", appearance: .light, in: self)
        }
    }
    
    func testHistory_SingleMeetingDetail_Light() throws {
        app = UITestHelpers.launchApp(
            useFixtures: true,
            appearance: .light
        )
        
        // Wait for main window
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(UITestHelpers.waitForElement(mainWindow, timeout: 3))
        
        // Double-click on a meeting to open detailed view
        let firstMeetingRow = app.tables.cells.firstMatch
        if UITestHelpers.waitForElement(firstMeetingRow, timeout: 2) {
            firstMeetingRow.doubleClick()
            
            // Wait for detail window to appear
            sleep(1)
            
            // Try to find the new window
            if app.windows.count > 1 {
                UITestHelpers.takeScreenshot(named: "history-meeting-detail", appearance: .light, in: self)
            }
        }
    }
    
    // MARK: - Dark Mode Screenshots
    
    func testHistory_EmptyState_Dark() throws {
        app = UITestHelpers.launchApp(appearance: .dark)
        
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(UITestHelpers.waitForElement(mainWindow, timeout: 3))
        
        let emptyStateText = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'no recordings' OR label CONTAINS[c] 'no meetings'")).firstMatch
        if UITestHelpers.waitForElement(emptyStateText, timeout: 2) {
            UITestHelpers.takeScreenshot(named: "history-empty-state", appearance: .dark, in: self)
        }
    }
    
    func testHistory_ListView_Dark() throws {
        app = UITestHelpers.launchApp(
            useFixtures: true,
            appearance: .dark
        )
        
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(UITestHelpers.waitForElement(mainWindow, timeout: 3))
        
        sleep(1)
        UITestHelpers.takeScreenshot(named: "history-list-view", appearance: .dark, in: self)
    }
    
    func testHistory_SplitView_Dark() throws {
        app = UITestHelpers.launchApp(
            useFixtures: true,
            appearance: .dark
        )
        
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(UITestHelpers.waitForElement(mainWindow, timeout: 3))
        
        let firstMeetingRow = app.tables.cells.firstMatch
        if UITestHelpers.waitForElement(firstMeetingRow, timeout: 2) {
            firstMeetingRow.click()
            sleep(1)
            UITestHelpers.takeScreenshot(named: "history-split-view", appearance: .dark, in: self)
        }
    }
}
