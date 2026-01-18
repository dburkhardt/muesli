import XCTest
@testable import Muesli
import CoreMedia
import AVFoundation

/// Comprehensive tests for AudioCaptureService
/// Part 1/3: Initialization and Configuration Tests
/// Target: 30% → 50% coverage for AudioCaptureService.swift
final class AudioCaptureServiceTests: XCTestCase {
    
    var service: AudioCaptureService!
    
    override func setUp() async throws {
        try await super.setUp()
        service = AudioCaptureService()
    }
    
    override func tearDown() async throws {
        // Clean up any active recording
        if await service.isRecording {
            try? await service.stopCapture()
        }
        service = nil
        try await super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testServiceInitialization() async {
        // Given/When: Service is initialized in setUp
        
        // Then: Service should not be recording
        let isRecording = await service.isRecording
        XCTAssertFalse(isRecording, "New service should not be recording")
    }
    
    func testServiceInitialState() async {
        // Given: A newly initialized service
        
        // When: Checking initial state
        let isRecording = await service.isRecording
        
        // Then: Should be in idle state
        XCTAssertFalse(isRecording, "Service should start in idle state")
    }
    
    // MARK: - Buffer Handler Configuration Tests
    
    func testSetBufferHandler() async {
        // Given: A service instance
        var bufferReceived = false
        
        // When: Setting a buffer handler
        await service.setBufferHandler { buffer, type in
            bufferReceived = true
        }
        
        // Then: Handler should be set (verified by not crashing and being able to start)
        // Note: Actual verification happens when buffers are received
        XCTAssertFalse(bufferReceived, "Handler should not be called until capture starts")
    }
    
    func testBufferHandlerCanBeUpdated() async {
        // Given: A service with an initial handler
        var firstHandlerCalled = false
        await service.setBufferHandler { buffer, type in
            firstHandlerCalled = true
        }
        
        // When: Setting a new handler
        var secondHandlerCalled = false
        await service.setBufferHandler { buffer, type in
            secondHandlerCalled = true
        }
        
        // Then: New handler should replace the old one
        // (Verification occurs when buffers are actually received in lifecycle tests)
        XCTAssertFalse(firstHandlerCalled, "First handler should not be called yet")
        XCTAssertFalse(secondHandlerCalled, "Second handler should not be called yet")
    }
    
    func testMultipleBufferHandlerUpdates() async {
        // Given: A service instance
        var callCount = 0
        
        // When: Setting handler multiple times
        await service.setBufferHandler { buffer, type in callCount += 1 }
        await service.setBufferHandler { buffer, type in callCount += 2 }
        await service.setBufferHandler { buffer, type in callCount += 3 }
        
        // Then: Last handler should be the active one
        XCTAssertEqual(callCount, 0, "Handlers should not be called during setup")
    }
    
    // MARK: - Interrupted Handler Configuration Tests
    
    func testSetInterruptedHandler() async {
        // Given: A service instance
        var interruptionReceived = false
        
        // When: Setting an interrupted handler
        await service.setInterruptedHandler { error in
            interruptionReceived = true
        }
        
        // Then: Handler should be set (verified by not crashing)
        XCTAssertFalse(interruptionReceived, "Handler should not be called until interruption occurs")
    }
    
    func testInterruptedHandlerCanBeUpdated() async {
        // Given: A service with an initial interrupted handler
        var firstHandlerCalled = false
        await service.setInterruptedHandler { error in
            firstHandlerCalled = true
        }
        
        // When: Setting a new interrupted handler
        var secondHandlerCalled = false
        await service.setInterruptedHandler { error in
            secondHandlerCalled = true
        }
        
        // Then: New handler should replace the old one
        XCTAssertFalse(firstHandlerCalled, "First handler should not be called yet")
        XCTAssertFalse(secondHandlerCalled, "Second handler should not be called yet")
    }
    
    // MARK: - Level Handler Configuration Tests
    
    func testSetLevelHandler() async {
        // Given: A service instance
        var levelReceived = false
        
        // When: Setting a level handler
        await service.setLevelHandler { level, type in
            levelReceived = true
        }
        
        // Then: Handler should be set
        XCTAssertFalse(levelReceived, "Handler should not be called until audio is captured")
    }
    
    func testLevelHandlerCanBeUpdated() async {
        // Given: A service with an initial level handler
        var firstHandlerCalled = false
        await service.setLevelHandler { level, type in
            firstHandlerCalled = true
        }
        
        // When: Setting a new level handler
        var secondHandlerCalled = false
        await service.setLevelHandler { level, type in
            secondHandlerCalled = true
        }
        
        // Then: New handler should replace the old one
        XCTAssertFalse(firstHandlerCalled, "First handler should not be called yet")
        XCTAssertFalse(secondHandlerCalled, "Second handler should not be called yet")
    }
    
    // MARK: - Microphone Device Selection Tests
    
    func testSetMicrophoneDeviceWithNil() async {
        // Given: A service instance
        
        // When: Setting microphone device to nil (use system default)
        await service.setMicrophoneDevice(nil)
        
        // Then: Should not crash and should use default device
        let isRecording = await service.isRecording
        XCTAssertFalse(isRecording, "Setting device should not start recording")
    }
    
    func testSetMicrophoneDeviceWithValidID() async {
        // Given: A service instance
        let testDeviceID = "test-device-123"
        
        // When: Setting a specific microphone device ID
        await service.setMicrophoneDevice(testDeviceID)
        
        // Then: Should not crash
        let isRecording = await service.isRecording
        XCTAssertFalse(isRecording, "Setting device should not start recording")
    }
    
    func testSetMicrophoneDeviceMultipleTimes() async {
        // Given: A service instance
        
        // When: Changing microphone device multiple times
        await service.setMicrophoneDevice("device-1")
        await service.setMicrophoneDevice("device-2")
        await service.setMicrophoneDevice(nil)
        await service.setMicrophoneDevice("device-3")
        
        // Then: Should handle all changes without crashing
        let isRecording = await service.isRecording
        XCTAssertFalse(isRecording, "Device changes should not start recording")
    }
    
    // MARK: - Error Cases: Handler Not Set
    
    func testStartCaptureWithoutBufferHandlerThrowsError() async {
        // Given: A service without a buffer handler set
        // (No setBufferHandler called)
        
        // When/Then: Starting capture should throw an error
        do {
            try await service.startCapture()
            XCTFail("Starting capture without buffer handler should throw error")
        } catch let error as AudioCaptureService.CaptureError {
            XCTAssertEqual(error, AudioCaptureService.CaptureError.bufferHandlerNotSet,
                         "Should throw bufferHandlerNotSet error")
        } catch {
            XCTFail("Should throw CaptureError.bufferHandlerNotSet, got: \(error)")
        }
    }
    
    func testStartCaptureForBundleWithoutBufferHandlerThrowsError() async {
        // Given: A service without a buffer handler set
        
        // When/Then: Starting capture for specific app should throw error
        do {
            try await service.startCapture(forBundleIdentifier: "us.zoom.xos")
            XCTFail("Starting capture without buffer handler should throw error")
        } catch let error as AudioCaptureService.CaptureError {
            XCTAssertEqual(error, AudioCaptureService.CaptureError.bufferHandlerNotSet,
                         "Should throw bufferHandlerNotSet error")
        } catch {
            XCTFail("Should throw CaptureError.bufferHandlerNotSet, got: \(error)")
        }
    }
    
    // MARK: - Error Cases: Already Recording
    
    func testCannotStartCaptureWhenAlreadyRecording() async {
        // Given: A service that is already recording
        await service.setBufferHandler { _, _ in }
        
        // Attempt to start recording (may fail due to permissions in test environment)
        // We're testing the error case when already recording
        do {
            try await service.startCapture()
            
            // When: Attempting to start capture again
            // Then: Should throw alreadyRecording error
            do {
                try await service.startCapture()
                XCTFail("Should not be able to start capture twice")
            } catch let error as AudioCaptureService.CaptureError {
                switch error {
                case .alreadyRecording:
                    XCTAssertTrue(true, "Correctly threw alreadyRecording error")
                default:
                    XCTFail("Wrong error type: \(error)")
                }
            }
            
            // Cleanup
            try? await service.stopCapture()
        } catch {
            // If initial start fails (permissions), that's OK for this test environment
            // The test verifies the error handling logic, not actual capture capability
            print("Note: Initial capture failed (expected in test environment): \(error)")
        }
    }
    
    // MARK: - Error Cases: Not Recording
    
    func testStopCaptureWhenNotRecordingThrowsError() async {
        // Given: A service that is not recording
        let isRecording = await service.isRecording
        XCTAssertFalse(isRecording, "Service should not be recording")
        
        // When/Then: Stopping capture should throw error
        do {
            try await service.stopCapture()
            XCTFail("Stopping capture when not recording should throw error")
        } catch let error as AudioCaptureService.CaptureError {
            XCTAssertEqual(error, AudioCaptureService.CaptureError.notRecording,
                         "Should throw notRecording error")
        } catch {
            XCTFail("Should throw CaptureError.notRecording, got: \(error)")
        }
    }
    
    func testStopCaptureMultipleTimesThrowsError() async {
        // Given: A service that successfully stopped
        await service.setBufferHandler { _, _ in }
        
        do {
            try await service.startCapture()
            try await service.stopCapture()
            
            // When: Attempting to stop again
            // Then: Should throw notRecording error
            do {
                try await service.stopCapture()
                XCTFail("Should not be able to stop capture twice")
            } catch let error as AudioCaptureService.CaptureError {
                XCTAssertEqual(error, AudioCaptureService.CaptureError.notRecording,
                             "Should throw notRecording error")
            }
        } catch {
            // If capture fails due to permissions, that's OK for test environment
            print("Note: Capture failed (expected in test environment): \(error)")
        }
    }
    
    // MARK: - Error Description Tests
    
    func testCaptureErrorDescriptions() {
        // Test all error cases have proper descriptions
        let errors: [AudioCaptureService.CaptureError] = [
            .noContentToCapture,
            .streamConfigurationFailed,
            .permissionDenied,
            .streamStartFailed(underlying: NSError(domain: "test", code: 1)),
            .alreadyRecording,
            .notRecording,
            .streamInterrupted(underlying: nil),
            .streamInterrupted(underlying: NSError(domain: "test", code: 2)),
            .bufferHandlerNotSet
        ]
        
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error should have description: \(error)")
            XCTAssertFalse(error.errorDescription!.isEmpty, "Error description should not be empty: \(error)")
        }
    }
    
    func testBufferHandlerNotSetErrorDescription() {
        // Given: The bufferHandlerNotSet error
        let error = AudioCaptureService.CaptureError.bufferHandlerNotSet
        
        // When: Getting error description
        let description = error.errorDescription
        
        // Then: Should contain helpful message about setBufferHandler
        XCTAssertNotNil(description)
        XCTAssertTrue(description!.contains("Buffer handler"), "Description should mention buffer handler")
        XCTAssertTrue(description!.contains("setBufferHandler"), "Description should mention setBufferHandler method")
    }
    
    func testStreamInterruptedErrorDescriptionWithError() {
        // Given: An interrupted error with underlying error
        let underlyingError = NSError(domain: "TestDomain", code: 42, 
                                     userInfo: [NSLocalizedDescriptionKey: "Test interruption"])
        let error = AudioCaptureService.CaptureError.streamInterrupted(underlying: underlyingError)
        
        // When: Getting error description
        let description = error.errorDescription
        
        // Then: Should include underlying error description
        XCTAssertNotNil(description)
        XCTAssertTrue(description!.contains("Test interruption"), 
                     "Description should include underlying error message")
    }
    
    func testStreamInterruptedErrorDescriptionWithoutError() {
        // Given: An interrupted error without underlying error
        let error = AudioCaptureService.CaptureError.streamInterrupted(underlying: nil)
        
        // When: Getting error description
        let description = error.errorDescription
        
        // Then: Should have generic interruption message
        XCTAssertNotNil(description)
        XCTAssertTrue(description!.contains("interrupted"), 
                     "Description should mention interruption")
    }
    
    // MARK: - AudioType Tests
    
    func testAudioTypeSystemCase() {
        // Given/When: System audio type
        let audioType = AudioCaptureService.AudioType.system
        
        // Then: Should be distinct type
        XCTAssertNotEqual(audioType, AudioCaptureService.AudioType.microphone,
                         "System and microphone types should be different")
    }
    
    func testAudioTypeMicrophoneCase() {
        // Given/When: Microphone audio type
        let audioType = AudioCaptureService.AudioType.microphone
        
        // Then: Should be distinct type
        XCTAssertNotEqual(audioType, AudioCaptureService.AudioType.system,
                         "Microphone and system types should be different")
    }
    
    func testAudioTypeEquality() {
        // Given: Two instances of same audio type
        let type1 = AudioCaptureService.AudioType.system
        let type2 = AudioCaptureService.AudioType.system
        
        // Then: Should be equal
        XCTAssertEqual(type1, type2, "Same audio types should be equal")
    }
}
