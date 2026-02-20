//
//  Muesli-CoreAudio-Bridging-Header.h
//  Muesli
//
//  Core Audio Tapping API bridging header
//  Uses AudioHardwareCreateProcessTap + CATapDescription (macOS 14.2+)
//

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>

// Import CATapDescription for process tap creation
#if __has_include(<CoreAudio/CATapDescription.h>)
#import <CoreAudio/CATapDescription.h>
#endif

// Import AudioHardwareTapping for AudioHardwareCreateProcessTap
#if __has_include(<CoreAudio/AudioHardwareTapping.h>)
#import <CoreAudio/AudioHardwareTapping.h>
#endif

// MARK: - Tap Property Selectors

// Property selector for getting tap's audio format
#ifndef kAudioTapPropertyFormat
#define kAudioTapPropertyFormat 'tfmt'
#endif

// MARK: - Runtime Availability

// AudioHardwareCreateProcessTap requires macOS 14.2+
// CATapDescription requires macOS 12.0+
// bundleIDs property on CATapDescription requires macOS 26.0+
