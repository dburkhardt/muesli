import Foundation

/// Represents a detected meeting application that can be captured
struct MeetingApp: Identifiable, Hashable {
    let id: String  // Bundle identifier
    let name: String
    let bundleIdentifier: String
    
    /// Known meeting app bundle identifiers
    static let knownBundleIDs: Set<String> = [
        "us.zoom.xos",           // Zoom
        "com.microsoft.teams",   // Microsoft Teams
        "com.google.Chrome",     // Google Meet (runs in Chrome)
        "com.apple.Safari",      // Google Meet (Safari)
        "com.microsoft.edgemac", // Teams/Meet in Edge
        "com.brave.Browser",     // Meet in Brave
        "org.mozilla.firefox",   // Meet in Firefox
        "com.vivaldi.Vivaldi"    // Meet in Vivaldi
    ]
    
    init(bundleIdentifier: String, name: String) {
        self.id = bundleIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }
}
