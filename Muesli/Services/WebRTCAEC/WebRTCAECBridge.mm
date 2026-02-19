//
//  WebRTCAECBridge.mm
//  Muesli
//
//  ObjC++ implementation of WebRTC AEC3 bridge
//  Uses os_unfair_lock for real-time safety and Accelerate for SIMD conversions
//

#import "WebRTCAECBridge.h"

// Conditionally include WebRTC headers if available
// Check various possible header paths based on how the XCFramework is configured
#if __has_include(<modules/audio_processing/include/audio_processing.h>)
#define WEBRTC_AVAILABLE 1
#define WEBRTC_AEC3_EXTERNAL_DELAY_FORCED 1
#include <modules/audio_processing/include/audio_processing.h>
#elif __has_include("modules/audio_processing/include/audio_processing.h")
#define WEBRTC_AVAILABLE 1
#define WEBRTC_AEC3_EXTERNAL_DELAY_FORCED 1
#include "modules/audio_processing/include/audio_processing.h"
#elif __has_include(<webrtc-audio-processing-2/modules/audio_processing/include/audio_processing.h>)
#define WEBRTC_AVAILABLE 1
#define WEBRTC_AEC3_EXTERNAL_DELAY_FORCED 1
#include <webrtc-audio-processing-2/modules/audio_processing/include/audio_processing.h>
#elif __has_include("webrtc-audio-processing-2/modules/audio_processing/include/audio_processing.h")
#define WEBRTC_AVAILABLE 1
#define WEBRTC_AEC3_EXTERNAL_DELAY_FORCED 1
#include "webrtc-audio-processing-2/modules/audio_processing/include/audio_processing.h"
#elif __has_include(<webrtc-audio-processing-1/modules/audio_processing/include/audio_processing.h>)
#define WEBRTC_AVAILABLE 1
#include <webrtc-audio-processing-1/modules/audio_processing/include/audio_processing.h>
#elif __has_include("webrtc-audio-processing-1/modules/audio_processing/include/audio_processing.h")
#define WEBRTC_AVAILABLE 1
#include "webrtc-audio-processing-1/modules/audio_processing/include/audio_processing.h"
#elif __has_include(<webrtc_audio_processing/modules/audio_processing/include/audio_processing.h>)
#define WEBRTC_AVAILABLE 1
#include <webrtc_audio_processing/modules/audio_processing/include/audio_processing.h>
#elif __has_include("modules/audio_processing/include/audio_processing.h")
#define WEBRTC_AVAILABLE 1
#include "modules/audio_processing/include/audio_processing.h"
#else
#define WEBRTC_AVAILABLE 0
#warning "WebRTC Audio Processing library not found - using stub implementation"
#endif

#include <os/lock.h>  // os_unfair_lock for real-time safety
#include <memory>
#include <array>
#include <atomic>
#include <Accelerate/Accelerate.h>

// Fixed frame size for 10ms @ 48kHz
static constexpr int kFrameSize = 480;

namespace {
#if WEBRTC_AVAILABLE
// Create AudioProcessing instance using v2.x API
// Note: In webrtc-audio-processing v2.x:
// - Create() returns rtc::scoped_refptr<AudioProcessing>, not raw pointer
// - EchoCanceller3 configuration is done via AudioProcessing::Config
inline rtc::scoped_refptr<webrtc::AudioProcessing> CreateApm() {
    return webrtc::AudioProcessingBuilder().Create();
}
#endif
}  // namespace

@implementation WebRTCAECBridge {
#if WEBRTC_AVAILABLE
    rtc::scoped_refptr<webrtc::AudioProcessing> _apm;
#endif
    os_unfair_lock _lock;  // Real-time safe lock (no priority inversion)
    int _sampleRate;
    int _channels;
    
    // Pre-allocated conversion buffers - EXACTLY frame size (no overflow possible)
    std::array<int16_t, kFrameSize> _renderInt16;
    std::array<int16_t, kFrameSize> _captureInt16;
    std::array<int16_t, kFrameSize> _outputInt16;
    std::array<float, kFrameSize> _conversionBuffer;
    
    // Cached stats (updated after each capture frame, read atomically)
    std::atomic<float> _cachedERLE;
    std::atomic<int> _cachedDelayMs;
    std::atomic<bool> _externalDelayEnabled;
}

- (nullable instancetype)initWithSampleRate:(int)sampleRate
                                   channels:(int)channels
                                      error:(NSError * _Nullable * _Nullable)error {
    self = [super init];
    if (self) {
        // Validate parameters
        if (sampleRate != 48000) {
            _lastError = WebRTCAECErrorInvalidConfig;
            if (error) {
                *error = [NSError errorWithDomain:@"WebRTCAEC"
                                             code:_lastError
                                         userInfo:@{NSLocalizedDescriptionKey: @"Sample rate must be 48000"}];
            }
            return nil;
        }
        if (channels != 1) {
            _lastError = WebRTCAECErrorInvalidConfig;
            if (error) {
                *error = [NSError errorWithDomain:@"WebRTCAEC"
                                             code:_lastError
                                         userInfo:@{NSLocalizedDescriptionKey: @"Channels must be 1 (mono)"}];
            }
            return nil;
        }
        
        _sampleRate = sampleRate;
        _channels = channels;
        _frameSize = kFrameSize;
        _lock = OS_UNFAIR_LOCK_INIT;
        _cachedERLE.store(0.0f);
        _cachedDelayMs.store(-1);
        _externalDelayEnabled.store(false);
        
#if WEBRTC_AVAILABLE
        // Create AudioProcessing instance first, then apply config
        try {
            _apm = CreateApm();
            // In v2.x, external delay is managed via set_stream_delay_ms()
            // The old EchoCanceller3Config::delay.use_external_delay_estimator is not available
            _externalDelayEnabled.store(true);
            
            if (!_apm) {
                _lastError = WebRTCAECErrorInitFailed;
                if (error) {
                    *error = [NSError errorWithDomain:@"WebRTCAEC"
                                                 code:_lastError
                                             userInfo:@{NSLocalizedDescriptionKey: @"AudioProcessing::Create returned null"}];
                }
                return nil;
            }
            
            // Configure AEC3 echo cancellation using v2.x API
            webrtc::AudioProcessing::Config config;
            config.echo_canceller.enabled = true;
            config.echo_canceller.mobile_mode = false;  // Desktop mode (better for laptops)
            config.gain_controller1.enabled = false;
            config.noise_suppression.enabled = false;
            _apm->ApplyConfig(config);
            
        } catch (const std::exception& e) {
            _lastError = WebRTCAECErrorInitFailed;
            if (error) {
                *error = [NSError errorWithDomain:@"WebRTCAEC"
                                             code:_lastError
                                         userInfo:@{NSLocalizedDescriptionKey:
                                            [NSString stringWithFormat:@"Exception: %s", e.what()]}];
            }
            return nil;
        }
        
        _lastError = WebRTCAECErrorNone;
        _isReady = YES;
        
        NSLog(@"[WebRTCAEC] Initialized with WebRTC AEC3 v2.x, sampleRate=%d, frameSize=%d",
              sampleRate, kFrameSize);
#else
        // Stub implementation - pass through audio without echo cancellation
        _lastError = WebRTCAECErrorNone;
        _isReady = YES;
        
        NSLog(@"[WebRTCAEC] Initialized in STUB mode (WebRTC library not available)");
#endif
    }
    return self;
}

- (BOOL)processRenderFrame:(const float *)samples {
    if (!_isReady || !samples) return NO;

    // Note: This method reads exactly kFrameSize (480) samples from `samples`.
    // All callers (AECProcessor.feedRenderFrame) validate frame size at the Swift
    // layer before calling. We cannot validate here because the API takes a raw
    // pointer without a count parameter.

    os_unfair_lock_lock(&_lock);
    
#if WEBRTC_AVAILABLE
    // Convert Float32 to Int16 using Accelerate (SIMD)
    float scale = 32767.0f;
    vDSP_vsmul(samples, 1, &scale, _conversionBuffer.data(), 1, kFrameSize);
    vDSP_vfix16(_conversionBuffer.data(), 1, _renderInt16.data(), 1, kFrameSize);
    
    // Process exactly one 10ms frame
    webrtc::StreamConfig streamConfig(_sampleRate, _channels);
    int result = _apm->ProcessReverseStream(
        _renderInt16.data(),
        streamConfig,
        streamConfig,
        _renderInt16.data()
    );
    
    os_unfair_lock_unlock(&_lock);
    
    if (result != 0) {
        _lastError = WebRTCAECErrorProcessingFailed;
        return NO;
    }
    return YES;
#else
    // Stub: just return success (no actual processing)
    os_unfair_lock_unlock(&_lock);
    return YES;
#endif
}

- (BOOL)processCaptureFrame:(const float *)samples outputSamples:(float *)outputSamples {
    if (!_isReady || !samples || !outputSamples) return NO;

    // Note: This method reads exactly kFrameSize (480) samples from `samples` and writes
    // kFrameSize samples to `outputSamples`. All callers (AECProcessor.processCaptureFrame)
    // validate frame size at the Swift layer before calling.

    os_unfair_lock_lock(&_lock);
    
#if WEBRTC_AVAILABLE
    // Convert Float32 to Int16
    float scale = 32767.0f;
    vDSP_vsmul(samples, 1, &scale, _conversionBuffer.data(), 1, kFrameSize);
    vDSP_vfix16(_conversionBuffer.data(), 1, _captureInt16.data(), 1, kFrameSize);
    
    // Process exactly one 10ms frame
    webrtc::StreamConfig streamConfig(_sampleRate, _channels);
    int result = _apm->ProcessStream(
        _captureInt16.data(),
        streamConfig,
        streamConfig,
        _outputInt16.data()
    );
    
    if (result != 0) {
        os_unfair_lock_unlock(&_lock);
        _lastError = WebRTCAECErrorProcessingFailed;
        return NO;
    }
    
    // Convert Int16 back to Float32
    float invScale = 1.0f / 32767.0f;
    vDSP_vflt16(_outputInt16.data(), 1, _conversionBuffer.data(), 1, kFrameSize);
    vDSP_vsmul(_conversionBuffer.data(), 1, &invScale, outputSamples, 1, kFrameSize);
    
    // Update cached stats (inside lock, read atomically outside)
    auto stats = _apm->GetStatistics();
    if (stats.echo_return_loss_enhancement.has_value()) {
        _cachedERLE.store(stats.echo_return_loss_enhancement.value());
    }
    if (stats.delay_ms.has_value()) {
        _cachedDelayMs.store(stats.delay_ms.value());
    }
    
    os_unfair_lock_unlock(&_lock);
    return YES;
#else
    // Stub: pass through input to output unchanged
    memcpy(outputSamples, samples, kFrameSize * sizeof(float));
    os_unfair_lock_unlock(&_lock);
    return YES;
#endif
}

- (BOOL)setStreamDelayMs:(int)delayMs {
    if (!_isReady) return NO;

    os_unfair_lock_lock(&_lock);

#if WEBRTC_AVAILABLE
    int result = _apm->set_stream_delay_ms(delayMs);
    os_unfair_lock_unlock(&_lock);
    if (result != 0) {
        _lastError = WebRTCAECErrorProcessingFailed;
        return NO;
    }
    return YES;
#else
    os_unfair_lock_unlock(&_lock);
    return YES;
#endif
}

- (void)reset {
    os_unfair_lock_lock(&_lock);
    
#if WEBRTC_AVAILABLE
    // Recreate AudioProcessing instance and apply config using v2.x API
    _apm = CreateApm();
    _externalDelayEnabled.store(true);
    if (_apm) {
        webrtc::AudioProcessing::Config config;
        config.echo_canceller.enabled = true;
        config.echo_canceller.mobile_mode = false;
        config.gain_controller1.enabled = false;
        config.noise_suppression.enabled = false;
        _apm->ApplyConfig(config);
    }
#endif
    
    _cachedERLE.store(0.0f);
    _cachedDelayMs.store(-1);
    
    os_unfair_lock_unlock(&_lock);
    
    NSLog(@"[WebRTCAEC] Reset complete");
}

// Lock-free reads of cached stats (safe to call from any thread)
- (float)getERLE {
    return _cachedERLE.load();
}

- (int)getDelayMs {
    return _cachedDelayMs.load();
}

- (BOOL)externalDelayEstimatorEnabled {
    return _externalDelayEnabled.load();
}

@end
