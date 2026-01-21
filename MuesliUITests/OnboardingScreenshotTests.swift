import XCTest

/// UI tests for capturing onboarding screenshots
final class OnboardingScreenshotTests: XCTestCase {
    
    var app: XCUIApplication!
    
    override func setUpWithError() throws {
        continueAfterFailure = false
    }
    
    // MARK: - Light Mode Screenshots
    
    func testOnboarding_Welcome_Light() throws {
        app = UITestHelpers.launchApp(
            skipOnboarding: false,
            mockPermissions: false,
            mockModels: false,
            appearance: .light
        )
        
        // Wait for welcome screen
        let welcomeText = app.staticTexts["Welcome to Muesli"]
        XCTAssertTrue(UITestHelpers.waitForElement(welcomeText, timeout: 3))
        
        // Take screenshot
        UITestHelpers.takeScreenshot(named: "onboarding-welcome", appearance: .light, in: self)
    }
    
    func testOnboarding_ScreenRecording_Light() throws {
        app = UITestHelpers.launchApp(
            skipOnboarding: false,
            mockPermissions: false,
            mockModels: false,
            appearance: .light
        )
        
        // Navigate to screen recording permission
        let continueButton = app.buttons["Continue"]
        if UITestHelpers.waitForElement(continueButton, timeout: 3) {
            continueButton.tap()
        }
        
        // Wait for screen recording screen
        let screenRecordingText = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'screen recording'")).firstMatch
        XCTAssertTrue(UITestHelpers.waitForElement(screenRecordingText, timeout: 3))
        
        // Take screenshot
        UITestHelpers.takeScreenshot(named: "onboarding-screen-recording", appearance: .light, in: self)
    }
    
    func testOnboarding_Microphone_Light() throws {
        app = UITestHelpers.launchApp(
            skipOnboarding: false,
            mockPermissions: false,
            mockModels: false,
            appearance: .light
        )
        
        // Navigate through welcome and screen recording (simulate granted)
        // Note: In real UI tests, we'd need to handle system dialogs or mock permissions
        // For now, we'll navigate as far as we can
        let continueButton = app.buttons["Continue"]
        
        // Skip welcome
        if UITestHelpers.waitForElement(continueButton, timeout: 3) {
            continueButton.tap()
            
            // Try to continue past screen recording (may fail if not granted)
            sleep(1)
            if continueButton.exists && continueButton.isEnabled {
                continueButton.tap()
            }
        }
        
        // Look for microphone screen
        let microphoneText = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'microphone'")).firstMatch
        if UITestHelpers.waitForElement(microphoneText, timeout: 2) {
            UITestHelpers.takeScreenshot(named: "onboarding-microphone", appearance: .light, in: self)
        }
    }
    
    func testOnboarding_ModelSetup_Light() throws {
        app = UITestHelpers.launchApp(
            skipOnboarding: false,
            mockPermissions: true, // Mock permissions to reach model setup
            mockModels: false,
            appearance: .light
        )
        
        // Wait for model setup screen
        let modelSetupText = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'whisper model'")).firstMatch
        if UITestHelpers.waitForElement(modelSetupText, timeout: 3) {
            UITestHelpers.takeScreenshot(named: "onboarding-model-setup", appearance: .light, in: self)
        }
    }
    
    func testOnboarding_LLMSetup_Light() throws {
        app = UITestHelpers.launchApp(
            skipOnboarding: false,
            mockPermissions: true,
            mockModels: true, // Mock Whisper model to reach LLM setup
            appearance: .light
        )
        
        // Wait for LLM setup screen
        let llmSetupText = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'llm' OR label CONTAINS[c] 'transcript refinement'")).firstMatch
        if UITestHelpers.waitForElement(llmSetupText, timeout: 3) {
            UITestHelpers.takeScreenshot(named: "onboarding-llm-setup", appearance: .light, in: self)
        }
    }
    
    // MARK: - Dark Mode Screenshots
    
    func testOnboarding_Welcome_Dark() throws {
        app = UITestHelpers.launchApp(
            skipOnboarding: false,
            mockPermissions: false,
            mockModels: false,
            appearance: .dark
        )
        
        let welcomeText = app.staticTexts["Welcome to Muesli"]
        XCTAssertTrue(UITestHelpers.waitForElement(welcomeText, timeout: 3))
        
        UITestHelpers.takeScreenshot(named: "onboarding-welcome", appearance: .dark, in: self)
    }
    
    func testOnboarding_ScreenRecording_Dark() throws {
        app = UITestHelpers.launchApp(
            skipOnboarding: false,
            mockPermissions: false,
            mockModels: false,
            appearance: .dark
        )
        
        let continueButton = app.buttons["Continue"]
        if UITestHelpers.waitForElement(continueButton, timeout: 3) {
            continueButton.tap()
        }
        
        let screenRecordingText = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'screen recording'")).firstMatch
        XCTAssertTrue(UITestHelpers.waitForElement(screenRecordingText, timeout: 3))
        
        UITestHelpers.takeScreenshot(named: "onboarding-screen-recording", appearance: .dark, in: self)
    }
    
    func testOnboarding_ModelSetup_Dark() throws {
        app = UITestHelpers.launchApp(
            skipOnboarding: false,
            mockPermissions: true,
            mockModels: false,
            appearance: .dark
        )
        
        let modelSetupText = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'whisper model'")).firstMatch
        if UITestHelpers.waitForElement(modelSetupText, timeout: 3) {
            UITestHelpers.takeScreenshot(named: "onboarding-model-setup", appearance: .dark, in: self)
        }
    }
}
