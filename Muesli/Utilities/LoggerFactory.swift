import os.log

/// Factory for creating os.log Logger instances with consistent subsystem
enum LoggerFactory {
    /// Subsystem identifier for all Muesli loggers
    private static let subsystem = "com.muesli.app"
    
    /// Create a logger for a specific category
    /// - Parameter category: The category name (usually the class/struct name)
    /// - Returns: Configured Logger instance
    static func logger(category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
