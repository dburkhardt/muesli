import XCTest

/// UI tests for capturing preferences screenshots
final class PreferencesScreenshotTests: XCTestCase {
    
    var app: XCUIApplication!
    
    override func setUpWithError() throws {
        continueAfterFailure = false
    }
    
    // MARK: - Light Mode Screenshots
    
    func testPreferences_GeneralTab_Light() throws {
        app = UITestHelpers.launchApp(appearance: .light)
        
        // Wait for app to launch
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(UITestHelpers.waitForElement(mainWindow, timeout: 3))
        
        // Open preferences
        UITestHelpers.openPreferences(in: app)
        
        // Wait for preferences window
        let preferencesWindow = app.windows["Preferences"]
        if UITestHelpers.waitForElement(preferencesWindow, timeout: 2) {
            // General tab should be selected by default
            sleep(1)
            UITestHelpers.takeScreenshot(named: "preferences-general", appearance: .light, in: self)
        }
    }
    
    func testPreferences_AdvancedTab_Light() throws {
        app = UITestHelpers.launchApp(appearance: .light)
        
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(UITestHelpers.waitForElement(mainWindow, timeout: 3))
        
        UITestHelpers.openPreferences(in: app)
        
        let preferencesWindow = app.windows["Preferences"]
        if UITestHelpers.waitForElement(preferencesWindow, timeout: 2) {
            // Click on Advanced tab
            let advancedTab = app.buttons["Advanced"]
            if UITestHelpers.waitForElement(advancedTab, timeout: 1) {
                advancedTab.click()
                sleep(1)
                UITestHelpers.takeScreenshot(named: "preferences-advanced", appearance: .light, in: self)
            }
        }
    }
    
    // MARK: - Dark Mode Screenshots
    
    func testPreferences_GeneralTab_Dark() throws {
        app = UITestHelpers.launchApp(appearance: .dark)
        
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(UITestHelpers.waitForElement(mainWindow, timeout: 3))
        
        UITestHelpers.openPreferences(in: app)
        
        let preferencesWindow = app.windows["Preferences"]
        if UITestHelpers.waitForElement(preferencesWindow, timeout: 2) {
            sleep(1)
            UITestHelpers.takeScreenshot(named: "preferences-general", appearance: .dark, in: self)
        }
    }
    
    func testPreferences_AdvancedTab_Dark() throws {
        app = UITestHelpers.launchApp(appearance: .dark)
        
        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(UITestHelpers.waitForElement(mainWindow, timeout: 3))
        
        UITestHelpers.openPreferences(in: app)
        
        let preferencesWindow = app.windows["Preferences"]
        if UITestHelpers.waitForElement(preferencesWindow, timeout: 2) {
            let advancedTab = app.buttons["Advanced"]
            if UITestHelpers.waitForElement(advancedTab, timeout: 1) {
                advancedTab.click()
                sleep(1)
                UITestHelpers.takeScreenshot(named: "preferences-advanced", appearance: .dark, in: self)
            }
        }
    }
}
