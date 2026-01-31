//
//  Muesli-CoreAudio-Bridging-Header.h
//  Muesli
//
//  Core Audio Tapping API bridging header
//  Requires macOS 26+ (Tahoe) for tap support
//

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>

// Core Audio Tap API definitions
// These are available in macOS 15.0+ (Sequoia) and fully supported in macOS 26+ (Tahoe)

#if __has_include(<CoreAudio/AudioHardwareTap.h>)
#import <CoreAudio/AudioHardwareTap.h>
#endif

// MARK: - Tap Description Constants

// These constants are used for building tap descriptions in aggregate devices
// Values are defined by Core Audio and may require runtime checks

// Tap description dictionary keys (for use with aggregate device tap lists)
#ifndef kAudioAggregateDeviceTapListKey
#define kAudioAggregateDeviceTapListKey CFSTR("tapl")
#endif

#ifndef kAudioAggregateDeviceTapAutoStartKey
#define kAudioAggregateDeviceTapAutoStartKey CFSTR("tpas")
#endif

// MARK: - Tap Property Selectors

// Property selector for tap format (on aggregate device input stream)
#ifndef kAudioTapPropertyFormat
#define kAudioTapPropertyFormat 'tfmt'
#endif

// MARK: - Process Handling

// For process exclusion, we use the process audit token or PID
// These are passed in tap description dictionaries

// MARK: - Helper Macros

// Check if Core Audio Taps are available at compile time
#if defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && __MAC_OS_X_VERSION_MAX_ALLOWED >= 150000
#define CORE_AUDIO_TAPS_AVAILABLE 1
#else
#define CORE_AUDIO_TAPS_AVAILABLE 0
#endif

// MARK: - Runtime Availability Check

// Use @available(macOS 15.0, *) in Swift for runtime checks
// Core Audio tap functionality requires:
// - macOS 15.0+ for basic tap support
// - macOS 26+ for full process exclusion tap support

// MARK: - Aggregate Device Tap Keys Reference

/*
 Aggregate device tap configuration uses these keys:
 
 kAudioAggregateDeviceTapListKey ("tapl") - Array of tap descriptions
 kAudioAggregateDeviceTapAutoStartKey ("tpas") - Boolean, auto-start tap
 
 Each tap description dictionary contains:
 - Device UID to tap
 - Process exclusion list (optional)
 - Exclusive mode flag (optional)
 
 The tap exposes an input stream on the aggregate device containing
 the mixed audio from the tapped output device, minus excluded processes.
*/
