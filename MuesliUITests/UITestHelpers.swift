import XCTest

/// Helper utilities for UI testing
enum UITestHelpers {
    
    // MARK: - Launch Arguments
    
    /// Launch argument to skip onboarding flow
    static let skipOnboarding = "-UITestingSkipOnboarding"
    
    /// Launch argument to mock permissions as granted
    static let mockPermissions = "-UITestingMockPermissions"
    
    /// Launch argument to use fixture transcript data
    static let useFixtures = "-UITestingUseFixtures"
    
    /// Launch argument to mock models as available
    static let mockModels = "-UITestingMockModels"
    
    /// Launch argument to enable light appearance
    static let useLightAppearance = "-UITestingLightAppearance"
    
    /// Launch argument to enable dark appearance
    static let useDarkAppearance = "-UITestingDarkAppearance"
    
    // MARK: - App Launch
    
    /// Launch the app with standard UI testing configuration
    /// - Parameters:
    ///   - skipOnboarding: Whether to skip the onboarding flow
    ///   - mockPermissions: Whether to mock permissions as granted
    ///   - useFixtures: Whether to use fixture data
    ///   - mockModels: Whether to mock models as available
    ///   - appearance: The appearance mode to use (light/dark/nil for system)
    /// - Returns: Configured XCUIApplication instance
    static func launchApp(
        skipOnboarding: Bool = true,
        mockPermissions: Bool = true,
        useFixtures: Bool = false,
        mockModels: Bool = true,
        appearance: XCUIUserInterfaceStyle? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        
        // Set launch arguments
        var launchArgs: [String] = []
        
        if skipOnboarding {
            launchArgs.append(Self.skipOnboarding)
        }
        if mockPermissions {
            launchArgs.append(Self.mockPermissions)
        }
        if useFixtures {
            launchArgs.append(Self.useFixtures)
        }
        if mockModels {
            launchArgs.append(Self.mockModels)
        }
        
        // Set appearance
        if let appearance = appearance {
            switch appearance {
            case .light:
                launchArgs.append(Self.useLightAppearance)
            case .dark:
                launchArgs.append(Self.useDarkAppearance)
            @unknown default:
                break
            }
        }
        
        app.launchArguments = launchArgs
        app.launch()
        
        return app
    }
    
    // MARK: - Screenshot Saving
    
    /// Save a screenshot to the project's docs/assets/screenshots directory
    /// - Parameters:
    ///   - attachment: The screenshot attachment
    ///   - name: The filename (without extension)
    ///   - appearance: The appearance mode (light/dark)
    static func saveScreenshot(_ attachment: XCTAttachment, name: String, appearance: XCUIUserInterfaceStyle) {
        let appearanceSuffix = appearance == .light ? "-light" : "-dark"
        attachment.name = "\(name)\(appearanceSuffix)"
        attachment.lifetime = .keepAlways
    }
    
    /// Take and save a screenshot with a descriptive name
    /// - Parameters:
    ///   - name: The screenshot name (without extension)
    ///   - appearance: The appearance mode
    ///   - testCase: The test case to attach the screenshot to
    static func takeScreenshot(
        named name: String,
        appearance: XCUIUserInterfaceStyle,
        in testCase: XCTestCase
    ) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        saveScreenshot(attachment, name: name, appearance: appearance)
        testCase.add(attachment)
    }
    
    // MARK: - Wait Helpers
    
    /// Wait for an element to exist
    /// - Parameters:
    ///   - element: The element to wait for
    ///   - timeout: Maximum time to wait (default: 5 seconds)
    /// - Returns: True if element exists within timeout
    @discardableResult
    static func waitForElement(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "exists == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        return result == .completed
    }
    
    /// Wait for an element to disappear
    /// - Parameters:
    ///   - element: The element to wait for
    ///   - timeout: Maximum time to wait (default: 5 seconds)
    /// - Returns: True if element disappears within timeout
    @discardableResult
    static func waitForElementToDisappear(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        return result == .completed
    }
    
    // MARK: - Navigation Helpers
    
    /// Open preferences window
    /// - Parameter app: The application instance
    static func openPreferences(in app: XCUIApplication) {
        // Use keyboard shortcut Cmd+,
        app.typeKey(",", modifierFlags: .command)
        // Wait for preferences window to appear
        _ = waitForElement(app.windows["Preferences"], timeout: 2)
    }
    
    /// Close current window
    /// - Parameter app: The application instance
    static func closeWindow(in app: XCUIApplication) {
        // Use keyboard shortcut Cmd+W
        app.typeKey("w", modifierFlags: .command)
    }
}
