import Foundation

/// Utility for formatting timestamps for display
enum TimeFormatting {
    /// Format a timestamp as a human-readable string
    /// - Parameters:
    ///   - seconds: Time interval in seconds
    ///   - style: Formatting style to use
    /// - Returns: Formatted timestamp string
    static func formatTimestamp(_ seconds: TimeInterval, style: Style = .standard) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        
        switch style {
        case .standard:
            // Zero-padded minutes: 00:10 or 1:23:45
            if hours > 0 {
                return String(format: "%d:%02d:%02d", hours, minutes, secs)
            } else {
                return String(format: "%02d:%02d", minutes, secs)
            }
            
        case .compact:
            // No zero-padding on minutes: 0:10 or 1:23:45
            if hours > 0 {
                return String(format: "%d:%02d:%02d", hours, minutes, secs)
            } else {
                return String(format: "%d:%02d", minutes, secs)
            }
            
        case .shortOnly:
            // Minutes and seconds only (no hours): 00:10
            // Calculate total minutes and remaining seconds
            let totalMinutes = totalSeconds / 60
            let remainingSeconds = totalSeconds % 60
            return String(format: "%02d:%02d", totalMinutes, remainingSeconds)
        }
    }
    
    /// Formatting style for timestamps
    enum Style {
        /// Zero-padded minutes, includes hours if needed (00:10 or 1:23:45)
        case standard
        /// No zero-padding on minutes, includes hours if needed (0:10 or 1:23:45)
        case compact
        /// Minutes and seconds only, always zero-padded (00:10)
        case shortOnly
    }
}
