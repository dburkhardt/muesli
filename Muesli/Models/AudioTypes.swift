//
//  AudioTypes.swift
//  Muesli
//
//  Shared audio types used across audio capture services.
//

import Foundation

/// Audio stream type identifier
/// Used by audio capture services and FileOutputService
enum AudioStreamType: Sendable {
    case system     // System audio (from tap or ScreenCaptureKit)
    case microphone // User's microphone audio
}
