import Foundation

/// Utility for detecting and extracting WorkTree identifier from bundle identifier
enum WorkTreeIdentifier {
    /// Extract WorkTree suffix from bundle identifier
    /// Returns `nil` if building from main branch (bundle ID is exactly "com.muesli.app")
    /// Returns suffix string if building from WorkTree (bundle ID is "com.muesli.app.<suffix>")
    static var workTreeSuffix: String? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let mainBundleID = "com.muesli.app"
        if bundleID == mainBundleID {
            return nil // Main branch
        }
        if bundleID.hasPrefix("\(mainBundleID).") {
            return String(bundleID.dropFirst(mainBundleID.count + 1))
        }
        return nil
    }
}
