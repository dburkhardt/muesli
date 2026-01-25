@testable import Muesli
import Foundation

/// Mock time provider for deterministic testing of time-dependent code.
/// Allows tests to control time progression without using Thread.sleep().
class MockTimeProvider: TimeProvider {
    /// The current mock time in seconds
    var time: Double = 0
    
    func currentTime() -> Double {
        time
    }
    
    /// Advance the mock time by a specified interval
    /// - Parameter interval: Time to advance in seconds
    func advance(by interval: Double) {
        time += interval
    }
    
    /// Set the mock time to a specific value
    /// - Parameter newTime: The new time in seconds
    func set(to newTime: Double) {
        time = newTime
    }
}
