import SwiftUI

// MARK: - Recording Indicator

/// Animated indicator showing that a recording is in progress
struct RecordingIndicator: View {
    let elapsedTime: String
    var isInitializing: Bool = false
    var isModelLoading: Bool = false
    var isRecordingOnly: Bool = false
    @State private var isPulsing = false
    
    var body: some View {
        HStack(spacing: 6) {
            if isInitializing {
                // Loading spinner when initializing
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
                
                Text("Starting...")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                // Pulsing red dot
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .opacity(isPulsing ? 0.5 : 1.0)
                    .scaleEffect(isPulsing ? 0.9 : 1.0)
                    .animation(
                        .easeInOut(duration: 0.8)
                        .repeatForever(autoreverses: true),
                        value: isPulsing
                    )
                
                Text("REC")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.red)
                
                Text(elapsedTime)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                
                // Model state indicator
                if isModelLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                        .help("Transcription model loading...")
                } else if isRecordingOnly {
                    Image(systemName: "waveform.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help("Recording audio only (transcription unavailable)")
                } else {
                    Image(systemName: "text.append")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                        .help("Live transcription active")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isInitializing ? Color.blue.opacity(0.1) : Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onAppear {
            isPulsing = true
        }
    }
}

// MARK: - Completed Indicator

/// Indicator showing that a recording has been saved
struct CompletedIndicator: View {
    @State private var showCheckmark = false
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
                .scaleEffect(showCheckmark ? 1.0 : 0.5)
                .opacity(showCheckmark ? 1.0 : 0.0)
                .animation(.spring(response: 0.4, dampingFraction: 0.6), value: showCheckmark)
            
            Text("Saved")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.green.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onAppear {
            showCheckmark = true
        }
    }
}

// MARK: - Interrupted Indicator

/// Indicator showing that a recording was interrupted
struct InterruptedIndicator: View {
    let reason: String?
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            
            Text("Interrupted")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help(reason ?? "The recording was interrupted")
    }
}

// MARK: - Microphone Level Indicator

/// Visual indicator showing microphone input level
/// The mic icon fills from bottom to top with a lighter shade based on audio amplitude
/// Uses VU-meter style ballistics: fast attack (~50ms), slower release (~300ms)
struct MicrophoneLevelIndicator: View {
    let level: Float  // 0.0 to 1.0
    let isActive: Bool
    
    // Smoothed display level with VU-meter ballistics
    @State private var displayLevel: CGFloat = 0.0
    
    private let iconSize: CGFloat = 18
    
    // VU-meter ballistics coefficients (per update, assuming ~20ms update rate)
    // Attack: fast rise when signal increases (~50ms to reach target)
    // Release: slower fall when signal decreases (~300ms to reach target)
    private let attackCoeff: CGFloat = 0.4   // Higher = faster attack
    private let releaseCoeff: CGFloat = 0.08 // Lower = slower release
    
    var body: some View {
        // Use overlay approach: base icon with colored rectangle overlay clipped to icon shape
        Image(systemName: "mic.fill")
            .font(.system(size: iconSize))
            .foregroundStyle(.blue.opacity(0.4))
            .overlay(alignment: .bottom) {
                // Colored fill that grows from bottom
                Rectangle()
                    .fill(.blue)
                    .frame(height: iconSize * displayLevel)
                    // Use linear animation for smooth interpolation
                    .animation(.linear(duration: 0.05), value: displayLevel)
            }
            .mask {
                // Clip everything to mic shape
                Image(systemName: "mic.fill")
                    .font(.system(size: iconSize))
            }
            .frame(width: iconSize + 4, height: iconSize + 4)
            .onChange(of: level) { _, newValue in
                guard isActive else { return }
                
                let targetLevel = min(CGFloat(newValue), 1.0)
                
                // Apply VU-meter ballistics: fast attack, slow release
                if targetLevel > displayLevel {
                    // Attack: rising - use fast coefficient
                    displayLevel += (targetLevel - displayLevel) * attackCoeff
                } else {
                    // Release: falling - use slow coefficient
                    displayLevel += (targetLevel - displayLevel) * releaseCoeff
                }
            }
            .onChange(of: isActive) { _, active in
                if !active {
                    displayLevel = 0.0
                }
            }
    }
}

// MARK: - Microphone Control with Level

/// Microphone picker button with integrated level indicator and mute toggle
struct MicrophoneControlWithLevel: View {
    let level: Float
    let isRecording: Bool
    let isMuted: Bool
    let availableDevices: [MicrophoneManager.MicrophoneDevice]
    let selectedDeviceID: String?
    let onToggleMute: () -> Void
    let onSelectDevice: (String) -> Void
    
    private let iconSize: CGFloat = 18
    
    var body: some View {
        HStack(spacing: 6) {
            // Mute toggle button (clickable microphone icon)
            Button(action: {
                onToggleMute()
            }) {
                Group {
                    if isMuted {
                        // Show muted icon (no level indicator)
                        Image(systemName: "mic.slash.fill")
                            .font(.system(size: iconSize))
                            .foregroundStyle(.red)
                    } else {
                        // Show level indicator when not muted
                        MicrophoneLevelIndicator(level: level, isActive: isRecording)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(isMuted ? "Unmute microphone" : "Mute microphone")
            
            // Device picker menu (chevron only)
            Menu {
                ForEach(availableDevices) { device in
                    Button(action: {
                        onSelectDevice(device.id)
                    }) {
                        HStack {
                            Text(device.name)
                            if device.isDefault {
                                Text("(Default)")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                            if selectedDeviceID == device.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview("Recording") {
    RecordingIndicator(elapsedTime: "05:23")
        .padding()
}

#Preview("Completed") {
    CompletedIndicator()
        .padding()
}

#Preview("Interrupted") {
    InterruptedIndicator(reason: "The captured app was closed")
        .padding()
}

#Preview("Mic Level Low") {
    MicrophoneLevelIndicator(level: 0.3, isActive: true)
        .padding()
        .background(.gray.opacity(0.2))
}

#Preview("Mic Level Medium") {
    MicrophoneLevelIndicator(level: 0.6, isActive: true)
        .padding()
        .background(.gray.opacity(0.2))
}

#Preview("Mic Level High") {
    MicrophoneLevelIndicator(level: 0.9, isActive: true)
        .padding()
        .background(.gray.opacity(0.2))
}

// MARK: - Refinement Loading Indicator

/// Loading indicator shown while transcript refinement is in progress
struct RefinementLoadingIndicator: View {
    @State private var opacity: Double = 0.5
    @State private var rotation: Double = 0
    
    var body: some View {
        Image(systemName: "wand.and.stars")
            .font(.system(size: 17))
            .foregroundStyle(.purple)
            .opacity(opacity)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                // Pulsating opacity animation
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    opacity = 1.0
                }
                
                // Light rotation animation (15-20 degrees)
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    rotation = 18.0 // ~18 degrees
                }
            }
    }
}

// MARK: - Refinement Toggle Control

/// iOS-style toggle switch for switching between refined and original transcripts
struct RefinementToggleControl: View {
    @Binding var isOn: Bool
    
    private let trackWidth: CGFloat = 50
    private let trackHeight: CGFloat = 30
    private let thumbSize: CGFloat = 26
    private let thumbPadding: CGFloat = 2
    
    var body: some View {
        ZStack {
            // Track background
            RoundedRectangle(cornerRadius: trackHeight / 2)
                .fill(isOn ? Color.purple.opacity(0.2) : Color.gray.opacity(0.2))
                .frame(width: trackWidth, height: trackHeight)
            
            // Thumb with icon
            HStack {
                if isOn {
                    Spacer()
                }
                
                Circle()
                    .fill(.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                    .overlay {
                        // Icon inside thumb
                        Image(systemName: isOn ? "wand.and.stars" : "doc.text")
                            .font(.system(size: 11))
                            .foregroundStyle(isOn ? .purple : .gray)
                    }
                    .padding(thumbPadding)
                
                if !isOn {
                    Spacer()
                }
            }
            .frame(width: trackWidth, height: trackHeight)
        }
        .frame(width: trackWidth, height: trackHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isOn.toggle()
            }
        }
    }
}

#Preview("Refinement Loading") {
    RefinementLoadingIndicator()
        .padding()
        .background(.regularMaterial)
}

#Preview("Refinement Toggle ON") {
    RefinementToggleControl(isOn: .constant(true))
        .padding()
        .background(.regularMaterial)
}

#Preview("Refinement Toggle OFF") {
    RefinementToggleControl(isOn: .constant(false))
        .padding()
        .background(.regularMaterial)
}
