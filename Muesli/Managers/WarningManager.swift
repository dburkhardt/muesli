import AppKit
import Foundation
import os.log

/// Manages service warnings that should be displayed to the user
/// Warnings are non-blocking notifications about partial failures
@Observable
@MainActor
final class WarningManager {
    // MARK: - Logging
    
    private let logger = Logger(subsystem: "com.muesli.app", category: "WarningManager")
    
    // MARK: - State
    
    /// All warnings (including dismissed ones for tracking)
    private var allWarnings: [ServiceWarning] = []
    
    /// Active warnings that should be displayed (not dismissed)
    var activeWarnings: [ServiceWarning] {
        allWarnings.filter { !$0.isDismissed }
    }
    
    /// Whether there are any active warnings
    var hasActiveWarnings: Bool {
        !activeWarnings.isEmpty
    }
    
    /// Count of active warnings
    var activeWarningCount: Int {
        activeWarnings.count
    }
    
    // MARK: - Warning Management
    
    /// Add a new warning
    /// If a warning with the same category already exists and was dismissed,
    /// it will be resurfaced (undismissed) with updated details
    /// - Parameters:
    ///   - category: The category of the warning
    ///   - message: Short display message for UI
    ///   - details: Full error details for debugging
    ///   - canRetry: Whether the operation can be retried
    func addWarning(
        _ category: ServiceWarning.WarningCategory,
        message: String,
        details: String,
        canRetry: Bool = false
    ) {
        logger.warning("[\(category.rawValue)] \(message)")
        
        // Check if we already have a warning for this category
        if let index = allWarnings.firstIndex(where: { $0.category == category }) {
            // Update existing warning and resurface it
            allWarnings[index] = ServiceWarning(
                id: allWarnings[index].id,  // Keep same ID for animation continuity
                category: category,
                message: message,
                details: details,
                timestamp: Date(),
                canRetry: canRetry,
                isDismissed: false  // Resurface
            )
        } else {
            // Add new warning
            let warning = ServiceWarning(
                category: category,
                message: message,
                details: details,
                canRetry: canRetry
            )
            allWarnings.append(warning)
        }
    }
    
    /// Dismiss a warning by ID
    /// The warning is marked as dismissed but kept for tracking (to resurface if issue recurs)
    /// - Parameter id: The ID of the warning to dismiss
    func dismissWarning(_ id: UUID) {
        if let index = allWarnings.firstIndex(where: { $0.id == id }) {
            allWarnings[index].isDismissed = true
            logger.debug("Dismissed warning: \(self.allWarnings[index].category.rawValue)")
        }
    }
    
    /// Dismiss all warnings for a specific category
    /// - Parameter category: The category of warnings to dismiss
    func dismissWarnings(for category: ServiceWarning.WarningCategory) {
        for index in allWarnings.indices where allWarnings[index].category == category {
            allWarnings[index].isDismissed = true
        }
    }
    
    /// Clear all warnings (e.g., when starting a new recording)
    func clearAll() {
        allWarnings.removeAll()
        logger.debug("Cleared all warnings")
    }
    
    /// Clear only dismissed warnings (keep active ones)
    func clearDismissed() {
        allWarnings.removeAll { $0.isDismissed }
    }
    
    /// Copy warning details to clipboard
    /// - Parameter id: The ID of the warning to copy
    /// - Returns: True if copied successfully
    @discardableResult
    func copyWarningDetails(_ id: UUID) -> Bool {
        guard let warning = allWarnings.first(where: { $0.id == id }) else {
            return false
        }
        
        let formattedDetails = warning.formattedDetailsForCopy()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(formattedDetails, forType: .string)
        
        logger.debug("Copied warning details to clipboard: \(warning.category.rawValue)")
        return true
    }
    
    /// Copy all active warning details to clipboard
    /// - Returns: True if copied successfully
    @discardableResult
    func copyAllWarningDetails() -> Bool {
        guard !activeWarnings.isEmpty else {
            return false
        }
        
        let allDetails = activeWarnings
            .map { $0.formattedDetailsForCopy() }
            .joined(separator: "\n\n---\n\n")
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(allDetails, forType: .string)
        
        logger.debug("Copied \(self.activeWarnings.count) warning details to clipboard")
        return true
    }
    
    /// Get a warning by ID
    /// - Parameter id: The ID of the warning
    /// - Returns: The warning if found
    func getWarning(_ id: UUID) -> ServiceWarning? {
        allWarnings.first { $0.id == id }
    }
    
    /// Check if there's an active warning for a category
    /// - Parameter category: The category to check
    /// - Returns: True if there's an undismissed warning for this category
    func hasActiveWarning(for category: ServiceWarning.WarningCategory) -> Bool {
        activeWarnings.contains { $0.category == category }
    }
}
