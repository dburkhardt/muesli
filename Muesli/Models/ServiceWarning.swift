import Foundation

/// Represents a warning from a service that should be displayed to the user
/// Warnings are non-blocking notifications about partial failures
struct ServiceWarning: Identifiable, Equatable {
    let id: UUID
    let category: WarningCategory
    let message: String           // Short display message for UI
    let details: String           // Full error details for debugging
    let timestamp: Date
    let canRetry: Bool
    var isDismissed: Bool
    
    /// Categories of warnings corresponding to different services
    enum WarningCategory: String, CaseIterable, Sendable {
        case microphone = "Microphone"
        case systemAudio = "System Audio"
        case transcription = "Transcription"
        case fileOutput = "File Output"
        case export = "Export"
        case llmRefinement = "LLM Refinement"
        case modelLoading = "Model Loading"
        
        /// SF Symbol name for the category
        var iconName: String {
            switch self {
            case .microphone:
                return "mic.slash"
            case .systemAudio:
                return "speaker.slash"
            case .transcription:
                return "text.bubble"
            case .fileOutput:
                return "doc.badge.ellipsis"
            case .export:
                return "square.and.arrow.up.trianglebadge.exclamationmark"
            case .llmRefinement:
                return "sparkles"
            case .modelLoading:
                return "cpu"
            }
        }
    }
    
    init(
        id: UUID = UUID(),
        category: WarningCategory,
        message: String,
        details: String,
        timestamp: Date = Date(),
        canRetry: Bool = false,
        isDismissed: Bool = false
    ) {
        self.id = id
        self.category = category
        self.message = message
        self.details = details
        self.timestamp = timestamp
        self.canRetry = canRetry
        self.isDismissed = isDismissed
    }
    
    /// Generate a formatted string suitable for copying to clipboard for debugging
    func formattedDetailsForCopy() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        
        // Get app version and macOS version
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        
        return """
        [Muesli Warning] \(message)
        Time: \(dateFormatter.string(from: timestamp))
        Category: \(category.rawValue)
        
        Details:
        \(details)
        
        System Info:
        - App Version: \(appVersion)
        - macOS: \(osVersion)
        """
    }
    
    static func == (lhs: ServiceWarning, rhs: ServiceWarning) -> Bool {
        lhs.id == rhs.id
    }
}
