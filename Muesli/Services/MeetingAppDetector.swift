import AppKit
import Foundation

/// Service responsible for detecting running meeting applications
@MainActor
final class MeetingAppDetector: MeetingAppDetectorProtocol {
    // MARK: - Types
    
    struct DetectedApp: Identifiable, Hashable {
        let id: String  // Bundle identifier
        let name: String
        let bundleIdentifier: String
        
        // Conformance helpers
        static func == (lhs: DetectedApp, rhs: DetectedApp) -> Bool {
            lhs.bundleIdentifier == rhs.bundleIdentifier
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(bundleIdentifier)
        }
    }
    
    // MARK: - Known Meeting Apps
    
    /// Bundle identifiers of known meeting applications
    static let knownMeetingApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams": "Microsoft Teams",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.webex.meetingmanager": "Webex",
        "com.cisco.webexmeetingsapp": "Webex Meetings"
    ]
    
    /// Bundle identifiers of browsers that can host Google Meet, etc.
    static let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser",  // Arc
        "org.chromium.Chromium"
    ]
    
    // MARK: - Detection
    
    /// Detect currently running meeting applications
    /// Uses NSWorkspace which doesn't require permissions (unlike SCShareableContent)
    /// - Returns: Array of detected meeting apps that can be captured
    func detectMeetingApps() async -> [DetectedApp] {
        // Use NSWorkspace to get running apps - no permission required
        let runningApps = NSWorkspace.shared.runningApplications
        
        var detectedApps: [DetectedApp] = []
        var seenBundleIDs: Set<String> = []
        
        for app in runningApps {
            guard let bundleID = app.bundleIdentifier,
                  !bundleID.isEmpty,
                  !seenBundleIDs.contains(bundleID) else {
                continue
            }
            
            // Check if it's a known meeting app
            if let appName = Self.knownMeetingApps[bundleID] {
                detectedApps.append(DetectedApp(
                    id: bundleID,
                    name: appName,
                    bundleIdentifier: bundleID
                ))
                seenBundleIDs.insert(bundleID)
            }
            // Check if it's a browser (could be hosting Google Meet)
            else if Self.browserBundleIDs.contains(bundleID) {
                let name = app.localizedName ?? bundleID
                detectedApps.append(DetectedApp(
                    id: bundleID,
                    name: name,
                    bundleIdentifier: bundleID
                ))
                seenBundleIDs.insert(bundleID)
            }
        }
        
        return detectedApps
    }
    
    /// Refresh the list of running applications
    /// This should be called periodically or when the user opens the menu
    func refreshApps() async -> [DetectedApp] {
        await detectMeetingApps()
    }
}
