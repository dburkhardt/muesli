import QuartzCore

/// Injectable time source for testability in real-time audio code.
/// Uses CACurrentMediaTime which is monotonic and immune to clock adjustments.
protocol TimeProvider {
    /// Returns the current time in seconds.
    /// For production, this is CACurrentMediaTime() (monotonic).
    /// For tests, this can be controlled via MockTimeProvider.
    func currentTime() -> Double
}

/// Production implementation using CACurrentMediaTime (monotonic, immune to clock adjustments).
/// This is the default time provider used in production code.
struct SystemTimeProvider: TimeProvider {
    func currentTime() -> Double {
        CACurrentMediaTime()
    }
}
