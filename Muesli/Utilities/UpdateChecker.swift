import Foundation

/// Checks for app updates from GitHub releases
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()
    
    // MARK: - Types
    
    enum UpdateStatus: Equatable {
        case upToDate
        case updateAvailable(version: String, releaseNotes: String, downloadURL: URL)
        case error(String)
        
        static func == (lhs: UpdateStatus, rhs: UpdateStatus) -> Bool {
            switch (lhs, rhs) {
            case (.upToDate, .upToDate):
                return true
            case (.updateAvailable(let v1, let n1, let u1), .updateAvailable(let v2, let n2, let u2)):
                return v1 == v2 && n1 == n2 && u1 == u2
            case (.error(let e1), .error(let e2)):
                return e1 == e2
            default:
                return false
            }
        }
    }
    
    // MARK: - Properties
    
    private let githubAPIURL = "https://api.github.com/repos/dburkhardt/muesli/releases/latest"
    private let timeout: TimeInterval = 10.0
    
    /// Last check date stored in UserDefaults
    var lastCheckDate: Date? {
        get {
            guard let dateString = UserDefaults.standard.string(forKey: AppStorageKeys.lastUpdateCheckDate) else {
                return nil
            }
            let formatter = ISO8601DateFormatter()
            return formatter.date(from: dateString)
        }
        set {
            if let date = newValue {
                let formatter = ISO8601DateFormatter()
                UserDefaults.standard.set(formatter.string(from: date), forKey: AppStorageKeys.lastUpdateCheckDate)
            } else {
                UserDefaults.standard.removeObject(forKey: AppStorageKeys.lastUpdateCheckDate)
            }
        }
    }
    
    /// Skipped versions stored in UserDefaults
    private var skippedVersions: Set<String> {
        get {
            guard let data = UserDefaults.standard.data(forKey: AppStorageKeys.skippedVersions),
                  let array = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return Set(array)
        }
        set {
            let array = Array(newValue)
            if let data = try? JSONEncoder().encode(array) {
                UserDefaults.standard.set(data, forKey: AppStorageKeys.skippedVersions)
            }
        }
    }
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Check for updates from GitHub
    func checkForUpdates() async -> UpdateStatus {
        // Update last check date
        lastCheckDate = Date()
        
        do {
            // Create URL request
            guard let url = URL(string: githubAPIURL) else {
                return .error("Invalid URL")
            }
            
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
            
            // Fetch data
            let (data, response) = try await URLSession.shared.data(for: request)
            
            // Check response status
            guard let httpResponse = response as? HTTPURLResponse else {
                return .error("Invalid response")
            }
            
            guard httpResponse.statusCode == 200 else {
                return .error("GitHub API returned status code \(httpResponse.statusCode)")
            }
            
            // Parse JSON
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .error("Failed to parse response")
            }
            
            guard let tagName = json["tag_name"] as? String else {
                return .error("No tag_name in response")
            }
            
            // Extract version (remove 'v' prefix if present)
            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            
            // Get current version
            guard let currentVersion = getCurrentVersion() else {
                return .error("Could not determine current version")
            }
            
            // Check if this version should be skipped
            if shouldSkipVersion(remoteVersion) {
                return .upToDate
            }
            
            // Compare versions
            let comparison = compareVersions(current: currentVersion, remote: remoteVersion)
            
            if comparison == .orderedAscending {
                // Update available
                let releaseNotes = json["body"] as? String ?? "No release notes available."
                let htmlURL = json["html_url"] as? String ?? "https://github.com/dburkhardt/muesli/releases/latest"
                
                guard let downloadURL = URL(string: htmlURL) else {
                    return .error("Invalid download URL")
                }
                
                return .updateAvailable(version: remoteVersion, releaseNotes: releaseNotes, downloadURL: downloadURL)
            } else {
                return .upToDate
            }
            
        } catch let error as NSError {
            if error.domain == NSURLErrorDomain {
                if error.code == NSURLErrorTimedOut {
                    return .error("Connection timed out")
                } else if error.code == NSURLErrorNotConnectedToInternet {
                    return .error("No internet connection")
                }
            }
            return .error("Network error: \(error.localizedDescription)")
        }
    }
    
    /// Check if a version should be skipped
    func shouldSkipVersion(_ version: String) -> Bool {
        return skippedVersions.contains(version)
    }
    
    /// Mark a version as skipped
    func skipVersion(_ version: String) {
        var versions = skippedVersions
        versions.insert(version)
        skippedVersions = versions
    }
    
    /// Clear skipped versions
    func clearSkippedVersions() {
        skippedVersions = []
    }
    
    /// Check if enough time has passed since last check (24 hours)
    func shouldCheckForUpdates() -> Bool {
        guard let lastCheck = lastCheckDate else {
            return true
        }
        let dayInSeconds: TimeInterval = 24 * 60 * 60
        return Date().timeIntervalSince(lastCheck) >= dayInSeconds
    }
    
    // MARK: - Private Methods
    
    /// Get current app version from bundle
    private func getCurrentVersion() -> String? {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }
    
    /// Compare two semantic version strings
    /// - Returns: .orderedAscending if current < remote (update available)
    ///            .orderedSame if versions are equal
    ///            .orderedDescending if current > remote
    private func compareVersions(current: String, remote: String) -> ComparisonResult {
        let currentComponents = parseVersion(current)
        let remoteComponents = parseVersion(remote)
        
        // Compare major
        if currentComponents.major < remoteComponents.major {
            return .orderedAscending
        } else if currentComponents.major > remoteComponents.major {
            return .orderedDescending
        }
        
        // Compare minor
        if currentComponents.minor < remoteComponents.minor {
            return .orderedAscending
        } else if currentComponents.minor > remoteComponents.minor {
            return .orderedDescending
        }
        
        // Compare patch
        if currentComponents.patch < remoteComponents.patch {
            return .orderedAscending
        } else if currentComponents.patch > remoteComponents.patch {
            return .orderedDescending
        }
        
        return .orderedSame
    }
    
    /// Parse a version string into major, minor, patch components
    private func parseVersion(_ version: String) -> (major: Int, minor: Int, patch: Int) {
        // Remove 'v' prefix if present
        let cleanVersion = version.hasPrefix("v") ? String(version.dropFirst()) : version
        
        // Split by dots and take first 3 components
        let components = cleanVersion.split(separator: ".").prefix(3)
        
        let major = components.count > 0 ? Int(components[0].prefix(while: { $0.isNumber })) ?? 0 : 0
        let minor = components.count > 1 ? Int(components[1].prefix(while: { $0.isNumber })) ?? 0 : 0
        let patch = components.count > 2 ? Int(components[2].prefix(while: { $0.isNumber })) ?? 0 : 0
        
        return (major, minor, patch)
    }
}
