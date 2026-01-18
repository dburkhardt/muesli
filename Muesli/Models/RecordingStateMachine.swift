import Foundation

/// State machine for managing recording state transitions atomically
/// Prevents invalid state transitions and ensures consistency
@MainActor
struct RecordingStateMachine {
    // MARK: - State
    
    enum State: Equatable {
        case idle
        case initializing
        case recording
        case paused
        case stopping
        case completed
        case failed(reason: String)
    }
    
    private(set) var currentState: State = .idle
    
    // MARK: - State Query
    
    var isIdle: Bool {
        currentState == .idle
    }
    
    var isInitializing: Bool {
        if case .initializing = currentState { return true }
        return false
    }
    
    var isRecording: Bool {
        currentState == .recording
    }
    
    var isPaused: Bool {
        currentState == .paused
    }
    
    var isStopping: Bool {
        currentState == .stopping
    }
    
    var isCompleted: Bool {
        currentState == .completed
    }
    
    var isFailed: Bool {
        if case .failed = currentState { return true }
        return false
    }
    
    var failureReason: String? {
        if case .failed(let reason) = currentState {
            return reason
        }
        return nil
    }
    
    // MARK: - State Transitions
    
    /// Attempt to transition to initializing state (preparing to record)
    mutating func beginInitialization() -> Result<Void, TransitionError> {
        guard currentState == .idle else {
            return .failure(.invalidTransition(from: currentState, to: .initializing))
        }
        currentState = .initializing
        return .success(())
    }
    
    /// Attempt to transition from initializing to recording
    mutating func startRecording() -> Result<Void, TransitionError> {
        guard currentState == .initializing || currentState == .idle else {
            return .failure(.invalidTransition(from: currentState, to: .recording))
        }
        currentState = .recording
        return .success(())
    }
    
    /// Attempt to transition from recording to paused
    mutating func pause() -> Result<Void, TransitionError> {
        guard currentState == .recording else {
            return .failure(.invalidTransition(from: currentState, to: .paused))
        }
        currentState = .paused
        return .success(())
    }
    
    /// Attempt to transition from paused to recording
    mutating func resume() -> Result<Void, TransitionError> {
        guard currentState == .paused else {
            return .failure(.invalidTransition(from: currentState, to: .recording))
        }
        currentState = .recording
        return .success(())
    }
    
    /// Attempt to transition to stopping state
    mutating func beginStopping() -> Result<Void, TransitionError> {
        guard currentState == .recording || currentState == .paused || currentState == .initializing else {
            return .failure(.invalidTransition(from: currentState, to: .stopping))
        }
        currentState = .stopping
        return .success(())
    }
    
    /// Attempt to transition to completed state
    mutating func complete() -> Result<Void, TransitionError> {
        guard currentState == .stopping else {
            return .failure(.invalidTransition(from: currentState, to: .completed))
        }
        currentState = .completed
        return .success(())
    }
    
    /// Transition to failed state (can be called from any state except completed)
    mutating func fail(reason: String) -> Result<Void, TransitionError> {
        guard currentState != .completed else {
            return .failure(.cannotFailAfterCompletion)
        }
        currentState = .failed(reason: reason)
        return .success(())
    }
    
    /// Reset state machine to idle
    mutating func reset() {
        currentState = .idle
    }
    
    // MARK: - Error Types
    
    enum TransitionError: Error, LocalizedError {
        case invalidTransition(from: State, to: State)
        case cannotFailAfterCompletion
        
        var errorDescription: String? {
            switch self {
            case .invalidTransition(let from, let to):
                return "Cannot transition from \(from) to \(to)"
            case .cannotFailAfterCompletion:
                return "Cannot transition to failed state after completion"
            }
        }
    }
}

// MARK: - State Description

extension RecordingStateMachine.State: CustomStringConvertible {
    var description: String {
        switch self {
        case .idle:
            return "idle"
        case .initializing:
            return "initializing"
        case .recording:
            return "recording"
        case .paused:
            return "paused"
        case .stopping:
            return "stopping"
        case .completed:
            return "completed"
        case .failed(let reason):
            return "failed(\(reason))"
        }
    }
}
