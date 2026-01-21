@testable import Muesli
import XCTest

/// Tests for RecordingStateMachine
/// Focus: Comprehensive state transition testing (all valid and invalid paths)
@MainActor
final class RecordingStateMachineTests: XCTestCase {
    // MARK: - Part 1: Valid Transitions
    
    /// Test idle → initializing transition
    func testIdleToInitializing() {
        // Arrange
        var stateMachine = RecordingStateMachine()
        XCTAssertTrue(stateMachine.isIdle)
        
        // Act
        let result = stateMachine.beginInitialization()
        
        // Assert
        XCTAssertEqual(result, .success(()))
        XCTAssertTrue(stateMachine.isInitializing)
        XCTAssertFalse(stateMachine.isIdle)
    }
    
    /// Test initializing → recording transition
    func testInitializingToRecording() {
        // Arrange
        var stateMachine = RecordingStateMachine()
        _ = stateMachine.beginInitialization()
        XCTAssertTrue(stateMachine.isInitializing)
        
        // Act
        let result = stateMachine.startRecording()
        
        // Assert
        XCTAssertEqual(result, .success(()))
        XCTAssertTrue(stateMachine.isRecording)
        XCTAssertFalse(stateMachine.isInitializing)
    }
    
    /// Test idle → recording direct transition
    func testIdleToRecordingDirect() {
        // Arrange
        var stateMachine = RecordingStateMachine()
        XCTAssertTrue(stateMachine.isIdle)
        
        // Act
        let result = stateMachine.startRecording()
        
        // Assert
        XCTAssertEqual(result, .success(()))
        XCTAssertTrue(stateMachine.isRecording)
    }
    
    /// Test recording → paused transition
    func testRecordingToPaused() {
        // Arrange
        var stateMachine = RecordingStateMachine()
        _ = stateMachine.startRecording()
        XCTAssertTrue(stateMachine.isRecording)
        
        // Act
        let result = stateMachine.pause()
        
        // Assert
        XCTAssertEqual(result, .success(()))
        XCTAssertTrue(stateMachine.isPaused)
        XCTAssertFalse(stateMachine.isRecording)
    }
    
    /// Test paused → recording transition (resume)
    func testPausedToRecording() {
        // Arrange
        var stateMachine = RecordingStateMachine()
        _ = stateMachine.startRecording()
        _ = stateMachine.pause()
        XCTAssertTrue(stateMachine.isPaused)
        
        // Act
        let result = stateMachine.resume()
        
        // Assert
        XCTAssertEqual(result, .success(()))
        XCTAssertTrue(stateMachine.isRecording)
        XCTAssertFalse(stateMachine.isPaused)
    }
    
    /// Test recording → stopping transition
    func testRecordingToStopping() {
        // Arrange
        var stateMachine = RecordingStateMachine()
        _ = stateMachine.startRecording()
        XCTAssertTrue(stateMachine.isRecording)
        
        // Act
        let result = stateMachine.beginStopping()
        
        // Assert
        XCTAssertEqual(result, .success(()))
        XCTAssertTrue(stateMachine.isStopping)
        XCTAssertFalse(stateMachine.isRecording)
    }
    
    /// Test paused → stopping transition
    func testPausedToStopping() {
        // Arrange
        var stateMachine = RecordingStateMachine()
        _ = stateMachine.startRecording()
        _ = stateMachine.pause()
        XCTAssertTrue(stateMachine.isPaused)
        
        // Act
        let result = stateMachine.beginStopping()
        
        // Assert
        XCTAssertEqual(result, .success(()))
        XCTAssertTrue(stateMachine.isStopping)
    }
    
    /// Test initializing → stopping transition
    func testInitializingToStopping() {
        // Arrange
        var stateMachine = RecordingStateMachine()
        _ = stateMachine.beginInitialization()
        XCTAssertTrue(stateMachine.isInitializing)
        
        // Act
        let result = stateMachine.beginStopping()
        
        // Assert
        XCTAssertEqual(result, .success(()))
        XCTAssertTrue(stateMachine.isStopping)
    }
    
    /// Test stopping → completed transition
    func testStoppingToCompleted() {
        // Arrange
        var stateMachine = RecordingStateMachine()
        _ = stateMachine.startRecording()
        _ = stateMachine.beginStopping()
        XCTAssertTrue(stateMachine.isStopping)
        
        // Act
        let result = stateMachine.complete()
        
        // Assert
        XCTAssertEqual(result, .success(()))
        XCTAssertTrue(stateMachine.isCompleted)
        XCTAssertFalse(stateMachine.isStopping)
    }
    
    /// Test any state → failed transition
    func testAnyStateToFailed() {
        // Test from idle
        var stateMachine = RecordingStateMachine()
        var result = stateMachine.fail(reason: "Test error")
        XCTAssertEqual(result, .success(()))
        XCTAssertTrue(stateMachine.isFailed)
        XCTAssertEqual(stateMachine.failureReason, "Test error")
        
        // Test from recording
        stateMachine = RecordingStateMachine()
        _ = stateMachine.startRecording()
        result = stateMachine.fail(reason: "Recording failed")
        XCTAssertEqual(result, .success(()))
        XCTAssertTrue(stateMachine.isFailed)
        XCTAssertEqual(stateMachine.failureReason, "Recording failed")
        
        // Test from paused
        stateMachine = RecordingStateMachine()
        _ = stateMachine.startRecording()
        _ = stateMachine.pause()
        result = stateMachine.fail(reason: "Paused failed")
        XCTAssertEqual(result, .success(()))
        XCTAssertTrue(stateMachine.isFailed)
    }
    
    // MARK: - Part 2: Invalid Transitions
    
    /// Test cannot initialize when not idle
    func testCannotInitializeWhenNotIdle() {
        // From recording
        var stateMachine = RecordingStateMachine()
        _ = stateMachine.startRecording()
        
        let result = stateMachine.beginInitialization()
        
        if case .failure(let error) = result {
            XCTAssertTrue(error.localizedDescription.contains("Cannot transition"))
        } else {
            XCTFail("Expected failure but got success")
        }
        
        // Should still be recording
        XCTAssertTrue(stateMachine.isRecording)
    }
    
    /// Test cannot start recording from invalid states
    func testCannotStartRecordingFromInvalidState() {
        // From recording (already recording)
        var stateMachine = RecordingStateMachine()
        _ = stateMachine.startRecording()
        
        let result = stateMachine.startRecording()
        
        if case .failure(let error) = result {
            XCTAssertTrue(error.localizedDescription.contains("Cannot transition"))
        } else {
            XCTFail("Expected failure but got success")
        }
    }
    
    /// Test cannot pause when not recording
    func testCannotPauseWhenNotRecording() {
        // From idle
        var stateMachine = RecordingStateMachine()
        
        var result = stateMachine.pause()
        
        if case .failure(let error) = result {
            XCTAssertTrue(error.localizedDescription.contains("Cannot transition"))
        } else {
            XCTFail("Expected failure but got success")
        }
        
        // From paused (already paused)
        stateMachine = RecordingStateMachine()
        _ = stateMachine.startRecording()
        _ = stateMachine.pause()
        
        result = stateMachine.pause()
        
        if case .failure = result {
            XCTAssertTrue(true) // Expected failure
        } else {
            XCTFail("Expected failure but got success")
        }
    }
    
    /// Test cannot resume when not paused
    func testCannotResumeWhenNotPaused() {
        // From idle
        var stateMachine = RecordingStateMachine()
        
        var result = stateMachine.resume()
        
        if case .failure(let error) = result {
            XCTAssertTrue(error.localizedDescription.contains("Cannot transition"))
        } else {
            XCTFail("Expected failure but got success")
        }
        
        // From recording
        stateMachine = RecordingStateMachine()
        _ = stateMachine.startRecording()
        
        result = stateMachine.resume()
        
        if case .failure = result {
            XCTAssertTrue(true) // Expected failure
        } else {
            XCTFail("Expected failure but got success")
        }
    }
    
    /// Test cannot stop from invalid states
    func testCannotStopFromInvalidStates() {
        // From idle
        var stateMachine = RecordingStateMachine()
        
        var result = stateMachine.beginStopping()
        
        if case .failure(let error) = result {
            XCTAssertTrue(error.localizedDescription.contains("Cannot transition"))
        } else {
            XCTFail("Expected failure but got success")
        }
        
        // From completed
        stateMachine = RecordingStateMachine()
        _ = stateMachine.startRecording()
        _ = stateMachine.beginStopping()
        _ = stateMachine.complete()
        
        result = stateMachine.beginStopping()
        
        if case .failure = result {
            XCTAssertTrue(true) // Expected failure
        } else {
            XCTFail("Expected failure but got success")
        }
        
        // From failed
        stateMachine = RecordingStateMachine()
        _ = stateMachine.fail(reason: "Test")
        
        result = stateMachine.beginStopping()
        
        if case .failure = result {
            XCTAssertTrue(true) // Expected failure
        } else {
            XCTFail("Expected failure but got success")
        }
    }
    
    /// Test cannot complete when not stopping
    func testCannotCompleteWhenNotStopping() {
        // From idle
        var stateMachine = RecordingStateMachine()
        
        var result = stateMachine.complete()
        
        if case .failure(let error) = result {
            XCTAssertTrue(error.localizedDescription.contains("Cannot transition"))
        } else {
            XCTFail("Expected failure but got success")
        }
        
        // From recording
        stateMachine = RecordingStateMachine()
        _ = stateMachine.startRecording()
        
        result = stateMachine.complete()
        
        if case .failure = result {
            XCTAssertTrue(true) // Expected failure
        } else {
            XCTFail("Expected failure but got success")
        }
    }
    
    /// Test cannot fail after completed
    func testCannotFailAfterCompleted() {
        // Arrange
        var stateMachine = RecordingStateMachine()
        _ = stateMachine.startRecording()
        _ = stateMachine.beginStopping()
        _ = stateMachine.complete()
        XCTAssertTrue(stateMachine.isCompleted)
        
        // Act
        let result = stateMachine.fail(reason: "Should not work")
        
        // Assert
        if case .failure(let error) = result,
           case .cannotFailAfterCompletion = error as? RecordingStateMachine.TransitionError {
            XCTAssertTrue(true) // Expected this specific error
        } else {
            XCTFail("Expected cannotFailAfterCompletion error")
        }
        
        // Should still be completed
        XCTAssertTrue(stateMachine.isCompleted)
    }
    
    // MARK: - Part 3: State Queries & Reset
    
    /// Test state query helpers
    func testStateQueryHelpers() {
        var stateMachine = RecordingStateMachine()
        
        // Idle
        XCTAssertTrue(stateMachine.isIdle)
        XCTAssertFalse(stateMachine.isInitializing)
        XCTAssertFalse(stateMachine.isRecording)
        XCTAssertFalse(stateMachine.isPaused)
        XCTAssertFalse(stateMachine.isStopping)
        XCTAssertFalse(stateMachine.isCompleted)
        XCTAssertFalse(stateMachine.isFailed)
        XCTAssertNil(stateMachine.failureReason)
        
        // Initializing
        _ = stateMachine.beginInitialization()
        XCTAssertFalse(stateMachine.isIdle)
        XCTAssertTrue(stateMachine.isInitializing)
        XCTAssertFalse(stateMachine.isRecording)
        
        // Recording
        _ = stateMachine.startRecording()
        XCTAssertFalse(stateMachine.isInitializing)
        XCTAssertTrue(stateMachine.isRecording)
        XCTAssertFalse(stateMachine.isPaused)
        
        // Paused
        _ = stateMachine.pause()
        XCTAssertFalse(stateMachine.isRecording)
        XCTAssertTrue(stateMachine.isPaused)
        
        // Resume to recording
        _ = stateMachine.resume()
        XCTAssertTrue(stateMachine.isRecording)
        
        // Stopping
        _ = stateMachine.beginStopping()
        XCTAssertFalse(stateMachine.isRecording)
        XCTAssertTrue(stateMachine.isStopping)
        
        // Completed
        _ = stateMachine.complete()
        XCTAssertFalse(stateMachine.isStopping)
        XCTAssertTrue(stateMachine.isCompleted)
        XCTAssertFalse(stateMachine.isFailed)
    }
    
    /// Test failure reason extraction
    func testFailureReasonExtraction() {
        // No failure initially
        var stateMachine = RecordingStateMachine()
        XCTAssertNil(stateMachine.failureReason)
        
        // After failure
        _ = stateMachine.fail(reason: "Network error")
        XCTAssertTrue(stateMachine.isFailed)
        XCTAssertEqual(stateMachine.failureReason, "Network error")
        
        // Different failure reason
        stateMachine = RecordingStateMachine()
        _ = stateMachine.startRecording()
        _ = stateMachine.fail(reason: "Disk full")
        XCTAssertEqual(stateMachine.failureReason, "Disk full")
    }
    
    /// Test reset to idle from various states
    func testResetFromAnyState() {
        // Reset from recording
        var stateMachine = RecordingStateMachine()
        _ = stateMachine.startRecording()
        stateMachine.reset()
        XCTAssertTrue(stateMachine.isIdle)
        XCTAssertEqual(stateMachine.currentState, .idle)
        
        // Reset from paused
        stateMachine = RecordingStateMachine()
        _ = stateMachine.startRecording()
        _ = stateMachine.pause()
        stateMachine.reset()
        XCTAssertTrue(stateMachine.isIdle)
        
        // Reset from failed
        stateMachine = RecordingStateMachine()
        _ = stateMachine.fail(reason: "Test")
        stateMachine.reset()
        XCTAssertTrue(stateMachine.isIdle)
        XCTAssertNil(stateMachine.failureReason)
        
        // Reset from completed
        stateMachine = RecordingStateMachine()
        _ = stateMachine.startRecording()
        _ = stateMachine.beginStopping()
        _ = stateMachine.complete()
        stateMachine.reset()
        XCTAssertTrue(stateMachine.isIdle)
    }
    
    /// Test state description strings
    func testStateDescriptions() {
        var stateMachine = RecordingStateMachine()
        
        // Idle
        XCTAssertEqual(stateMachine.currentState.description, "idle")
        
        // Initializing
        _ = stateMachine.beginInitialization()
        XCTAssertEqual(stateMachine.currentState.description, "initializing")
        
        // Recording
        _ = stateMachine.startRecording()
        XCTAssertEqual(stateMachine.currentState.description, "recording")
        
        // Paused
        _ = stateMachine.pause()
        XCTAssertEqual(stateMachine.currentState.description, "paused")
        
        // Resume then stop
        _ = stateMachine.resume()
        _ = stateMachine.beginStopping()
        XCTAssertEqual(stateMachine.currentState.description, "stopping")
        
        // Completed
        _ = stateMachine.complete()
        XCTAssertEqual(stateMachine.currentState.description, "completed")
        
        // Failed
        stateMachine = RecordingStateMachine()
        _ = stateMachine.fail(reason: "test error")
        XCTAssertTrue(stateMachine.currentState.description.contains("failed"))
        XCTAssertTrue(stateMachine.currentState.description.contains("test error"))
    }
    
    /// Test state equality
    func testStateEquality() {
        XCTAssertEqual(RecordingStateMachine.State.idle, .idle)
        XCTAssertEqual(RecordingStateMachine.State.recording, .recording)
        XCTAssertNotEqual(RecordingStateMachine.State.idle, .recording)
        
        // Failed states are equal if reasons are equal
        XCTAssertEqual(RecordingStateMachine.State.failed(reason: "error1"), 
                      .failed(reason: "error1"))
        XCTAssertNotEqual(RecordingStateMachine.State.failed(reason: "error1"), 
                         .failed(reason: "error2"))
    }
    
    /// Test complete recording lifecycle
    func testCompleteRecordingLifecycle() {
        var stateMachine = RecordingStateMachine()
        
        // Start from idle
        XCTAssertTrue(stateMachine.isIdle)
        
        // Initialize
        XCTAssertEqual(stateMachine.beginInitialization(), .success(()))
        XCTAssertTrue(stateMachine.isInitializing)
        
        // Start recording
        XCTAssertEqual(stateMachine.startRecording(), .success(()))
        XCTAssertTrue(stateMachine.isRecording)
        
        // Pause
        XCTAssertEqual(stateMachine.pause(), .success(()))
        XCTAssertTrue(stateMachine.isPaused)
        
        // Resume
        XCTAssertEqual(stateMachine.resume(), .success(()))
        XCTAssertTrue(stateMachine.isRecording)
        
        // Stop
        XCTAssertEqual(stateMachine.beginStopping(), .success(()))
        XCTAssertTrue(stateMachine.isStopping)
        
        // Complete
        XCTAssertEqual(stateMachine.complete(), .success(()))
        XCTAssertTrue(stateMachine.isCompleted)
        
        // Reset and ready for next recording
        stateMachine.reset()
        XCTAssertTrue(stateMachine.isIdle)
    }
}
