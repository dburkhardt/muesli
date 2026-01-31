//
//  AudioTypes.swift
//  Muesli
//
//  Shared audio types used across audio capture services.
//  This allows both AudioCaptureService and TapAudioCaptureService
//  to use the same type definitions for seamless integration.
//

import Foundation

/// Audio stream type identifier
/// Used by audio capture services and FileOutputService
enum AudioStreamType: Sendable {
    case system     // System audio (from tap or ScreenCaptureKit)
    case microphone // User's microphone audio
}
