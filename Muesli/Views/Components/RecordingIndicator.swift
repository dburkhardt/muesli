import SwiftUI

// MARK: - Recording Indicator

/// Animated indicator showing that a recording is in progress
struct RecordingIndicator: View {
    let elapsedTime: String
    @State private var isPulsing = false
    
    var body: some View {
        HStack(spacing: 6) {
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
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.red.opacity(0.1))
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
                    displayLevel = displayLevel + (targetLevel - displayLevel) * attackCoeff
                } else {
                    // Release: falling - use slow coefficient
                    displayLevel = displayLevel + (targetLevel - displayLevel) * releaseCoeff
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

/// Microphone picker button with integrated level indicator
struct MicrophoneControlWithLevel: View {
    let level: Float
    let isRecording: Bool
    let availableDevices: [MicrophoneManager.MicrophoneDevice]
    let selectedDeviceID: String?
    let onSelectDevice: (String) -> Void
    
    var body: some View {
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
            HStack(spacing: 4) {
                MicrophoneLevelIndicator(level: level, isActive: isRecording)
                
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
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
