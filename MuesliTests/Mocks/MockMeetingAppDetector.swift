import Foundation
@testable import Muesli

/// Mock implementation of MeetingAppDetector for testing
@MainActor
final class MockMeetingAppDetector: MeetingAppDetectorProtocol {
    
    // MARK: - Test Data
    
    /// Apps to return from detectMeetingApps()
    var mockApps: [MeetingAppDetector.DetectedApp] = []
    
    // MARK: - Call Tracking
    
    var detectMeetingAppsCallCount: Int = 0
    var refreshAppsCallCount: Int = 0
    
    // MARK: - MeetingAppDetectorProtocol
    
    func detectMeetingApps() async -> [MeetingAppDetector.DetectedApp] {
        detectMeetingAppsCallCount += 1
        return mockApps
    }
    
    func refreshApps() async -> [MeetingAppDetector.DetectedApp] {
        refreshAppsCallCount += 1
        return mockApps
    }
    
    // MARK: - Test Helpers
    
    /// Create a mock detected app
    static func createMockApp(
        bundleIdentifier: String = "com.test.app",
        name: String = "Test App"
    ) -> MeetingAppDetector.DetectedApp {
        MeetingAppDetector.DetectedApp(
            id: bundleIdentifier,
            name: name,
            bundleIdentifier: bundleIdentifier
        )
    }
    
    /// Add common mock meeting apps
    func addCommonMeetingApps() {
        mockApps = [
            MeetingAppDetector.DetectedApp(id: "us.zoom.xos", name: "Zoom", bundleIdentifier: "us.zoom.xos"),
            MeetingAppDetector.DetectedApp(id: "com.microsoft.teams", name: "Microsoft Teams", bundleIdentifier: "com.microsoft.teams"),
            MeetingAppDetector.DetectedApp(id: "com.google.Chrome", name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        ]
    }
    
    /// Reset all state for next test
    func reset() {
        mockApps = []
        detectMeetingAppsCallCount = 0
        refreshAppsCallCount = 0
    }
}
