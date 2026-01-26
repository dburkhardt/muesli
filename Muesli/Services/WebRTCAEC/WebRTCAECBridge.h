//
//  WebRTCAECBridge.h
//  Muesli
//
//  Thread-safe wrapper for WebRTC's AudioProcessing module (AEC3)
//  Uses os_unfair_lock for real-time safety (no priority inversion).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Error codes for WebRTC AEC initialization and processing
typedef NS_ENUM(NSInteger, WebRTCAECError) {
    WebRTCAECErrorNone = 0,
    WebRTCAECErrorInitFailed = 1,
    WebRTCAECErrorInvalidConfig = 2,
    WebRTCAECErrorProcessingFailed = 3,
    WebRTCAECErrorInvalidFrameSize = 4,  // Must be exactly 480 samples
    WebRTCAECErrorBufferOverflow = 5,     // Input exceeds max buffer
};

/// Thread-safe wrapper for WebRTC's AudioProcessing module (AEC3)
/// Uses os_unfair_lock for real-time safety (no priority inversion).
///
/// CRITICAL: All processing methods expect EXACTLY 480 samples (10ms @ 48kHz).
/// Partial frames will be rejected with WebRTCAECErrorInvalidFrameSize.
///
/// On failure, outputSamples contents are UNDEFINED. Caller should pass through
/// the original samples to preserve audio continuity.
@interface WebRTCAECBridge : NSObject

/// Initialize with sample rate (must be 48000) and channels (must be 1 for mono)
/// @param sampleRate Audio sample rate (must be 48000)
/// @param channels Number of audio channels (must be 1 for mono)
/// @param error Optional error output for initialization failures
/// @return Initialized instance, or nil if initialization fails
- (nullable instancetype)initWithSampleRate:(int)sampleRate
                                   channels:(int)channels
                                      error:(NSError * _Nullable * _Nullable)error;

/// Process render (speaker/system) audio - call this BEFORE capture processing
/// @param samples Float32 audio samples (mono, MUST be exactly 480 samples)
/// @return YES if successful, NO if error (check lastError)
/// @note On failure, check lastError. WebRTCAECErrorInvalidFrameSize means wrong count.
- (BOOL)processRenderFrame:(const float *)samples;

/// Process capture (microphone) audio and apply echo cancellation
/// @param samples Float32 audio samples (mono, MUST be exactly 480 samples)
/// @param outputSamples Buffer to receive processed samples (pre-allocated, 480 samples)
/// @return YES if successful, NO if error
/// @note On failure, outputSamples is UNDEFINED. Caller should pass through original.
- (BOOL)processCaptureFrame:(const float *)samples
              outputSamples:(float *)outputSamples;

/// Reset the AEC state (call when starting new recording)
- (void)reset;

/// Get estimated echo return loss enhancement (ERLE) in dB
/// Returns 0 if not yet converged. Safe to call from any thread.
- (float)getERLE;

/// Get current delay estimate in milliseconds
/// Returns -1 if not yet estimated. Safe to call from any thread.
- (int)getDelayMs;

/// Check if AEC is initialized and ready
@property (nonatomic, readonly) BOOL isReady;

/// Last error code
@property (nonatomic, readonly) WebRTCAECError lastError;

/// Frame size (always 480 for 10ms @ 48kHz)
@property (nonatomic, readonly) int frameSize;

@end

NS_ASSUME_NONNULL_END
