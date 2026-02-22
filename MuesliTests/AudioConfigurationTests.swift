@testable import Muesli
import XCTest

/// Tests for AudioConfiguration constants and computed properties
final class AudioConfigurationTests: XCTestCase {

    // MARK: - Sample Rate Tests

    func testWhisperSampleRate() {
        XCTAssertEqual(AudioConfiguration.whisperSampleRate, 16000)
    }

    func testCaptureSampleRate() {
        XCTAssertEqual(AudioConfiguration.captureSampleRate, 48000)
    }

    func testCaptureChannelCount() {
        XCTAssertEqual(AudioConfiguration.captureChannelCount, 2)
    }

    func testMicrophoneSampleRate() {
        XCTAssertEqual(AudioConfiguration.microphoneSampleRate, 48000)
    }

    // MARK: - Transcription Timing Tests

    func testTranscriptionChunkDuration() {
        XCTAssertEqual(AudioConfiguration.transcriptionChunkDuration, 15.0)
    }

    func testTranscriptionOverlapDuration() {
        XCTAssertEqual(AudioConfiguration.transcriptionOverlapDuration, 3.0)
    }

    func testWarmupChunkDuration() {
        XCTAssertEqual(AudioConfiguration.warmupChunkDuration, 5.0)
    }

    func testWarmupChunkCount() {
        XCTAssertEqual(AudioConfiguration.warmupChunkCount, 1)
    }

    func testPostProcessingChunkDuration() {
        XCTAssertEqual(AudioConfiguration.postProcessingChunkDuration, 30.0)
    }

    // MARK: - Computed Properties Tests

    func testMinSamplesForProcessing() {
        let expected = AudioConfiguration.whisperSampleRate * Int(AudioConfiguration.transcriptionChunkDuration)
        XCTAssertEqual(AudioConfiguration.minSamplesForProcessing, expected)
        XCTAssertEqual(AudioConfiguration.minSamplesForProcessing, 240_000)
    }

    func testOverlapSamples() {
        let expected = AudioConfiguration.whisperSampleRate * Int(AudioConfiguration.transcriptionOverlapDuration)
        XCTAssertEqual(AudioConfiguration.overlapSamples, expected)
        XCTAssertEqual(AudioConfiguration.overlapSamples, 48_000)
    }

    func testWarmupMinSamples() {
        let expected = AudioConfiguration.whisperSampleRate * Int(AudioConfiguration.warmupChunkDuration)
        XCTAssertEqual(AudioConfiguration.warmupMinSamples, expected)
        XCTAssertEqual(AudioConfiguration.warmupMinSamples, 80_000)
    }

    func testWarmupOverlapSamples() {
        let expected = AudioConfiguration.whisperSampleRate * Int(AudioConfiguration.warmupOverlapDuration)
        XCTAssertEqual(AudioConfiguration.warmupOverlapSamples, expected)
        XCTAssertEqual(AudioConfiguration.warmupOverlapSamples, 16_000)
    }

    // MARK: - Buffer Management Tests

    func testBufferTimeoutSeconds() {
        XCTAssertEqual(AudioConfiguration.bufferTimeoutSeconds, 300.0)
    }

    func testMaxBufferSamples() {
        XCTAssertEqual(AudioConfiguration.maxBufferSamples, 480_000)
        // 30 seconds at 16kHz
        XCTAssertEqual(AudioConfiguration.maxBufferSamples, 30 * 16000)
    }

    func testMaxQueuedBuffers() {
        XCTAssertEqual(AudioConfiguration.maxQueuedBuffers, 10)
    }

    // MARK: - VAD Tests

    func testVadThreshold() {
        XCTAssertEqual(AudioConfiguration.vadThreshold, 0.01)
    }

    // MARK: - Error Recovery Tests

    func testMaxConsecutiveAudioErrors() {
        XCTAssertEqual(AudioConfiguration.maxConsecutiveAudioErrors, 100)
    }

    func testMaxModelRetries() {
        XCTAssertEqual(AudioConfiguration.maxModelRetries, 3)
    }

    // MARK: - AEC Configuration Tests

    func testAECConstants() {
        XCTAssertEqual(AudioConfiguration.aecAcousticDelayMs, 50)
        XCTAssertEqual(AudioConfiguration.aecFilterLength, 1024)
        XCTAssertEqual(AudioConfiguration.aecLearningRate, 0.2)
        XCTAssertEqual(AudioConfiguration.aecGapThresholdMs, 50)
        XCTAssertEqual(AudioConfiguration.aecMaxGapMs, 500)
        XCTAssertEqual(AudioConfiguration.maxSystemAudioBuffers, 150)
    }

    // MARK: - Consistency Tests

    func testOverlapShorterThanChunk() {
        XCTAssertLessThan(AudioConfiguration.transcriptionOverlapDuration, AudioConfiguration.transcriptionChunkDuration)
        XCTAssertLessThan(AudioConfiguration.warmupOverlapDuration, AudioConfiguration.warmupChunkDuration)
        XCTAssertLessThan(AudioConfiguration.postProcessingOverlapDuration, AudioConfiguration.postProcessingChunkDuration)
    }

    func testWarmupShorterThanSteadyState() {
        XCTAssertLessThan(AudioConfiguration.warmupChunkDuration, AudioConfiguration.transcriptionChunkDuration)
    }
}
