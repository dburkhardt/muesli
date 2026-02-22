# Wrong Default Microphone Selection with Virtual Audio Drivers

**Date**: 2026-02-22
**Category**: Audio

## Problem Description

On systems with virtual audio drivers (JustStream, BlackHole, Steam Audio, etc.), the wrong microphone was silently selected as the default — causing empty `microphone.caf` recordings.

## Symptoms/Error Messages

- `microphone.caf` recordings are empty or contain silence
- The "(Default)" label in the mic picker doesn't match System Settings > Sound > Input
- Only affects systems with virtual audio drivers installed; works correctly on clean systems with only built-in hardware

## Root Cause Analysis

`MicrophoneManager.refreshDevices()` and `currentDefaultDevice` assumed that `AVCaptureDevice.DiscoverySession.devices.first` was the system default microphone. In reality, the discovery session ordering is **arbitrary and unreliable** — it does not reflect the user's configured default in System Settings. On systems with virtual audio drivers, a virtual device often appeared first in the list, causing Muesli to auto-select it instead of the actual physical microphone.

## Fix Description

Replaced the `devices.first` heuristic with a proper Core Audio query using `kAudioHardwarePropertyDefaultInputDevice` (via existing `CoreAudioHelpers.getDefaultInputDevice()` + `getDeviceUID()`). The system default is matched by UID against the discovered devices. If the Core Audio query fails or the UID isn't found, falls back to the first eligible device.

Both `refreshDevices()` and `currentDefaultDevice` were updated consistently. A reusable `selectDefaultDevice(systemDefaultUID:devices:)` static helper was extracted for testability.

## Affected Files

- `Muesli/Utilities/MicrophoneManager.swift` - Added `getSystemDefaultInputUID()` and `selectDefaultDevice()` helpers; refactored `refreshDevices()` and `currentDefaultDevice` to use Core Audio default
- `Muesli/Services/TapAudioCaptureService.swift` - Improved warning log accuracy when a requested mic UID isn't found

## Code Snippets

### Before

```swift
// MicrophoneManager.refreshDevices() — assumed first device is default
let defaultDevice = captureDevices.first
```

### After

```swift
// Query Core Audio for the true system default input device
let systemDefaultUID = Self.getSystemDefaultInputUID()
// ... build filtered device list ...
if let chosen = Self.selectDefaultDevice(systemDefaultUID: systemDefaultUID, devices: devices),
   let idx = devices.firstIndex(where: { $0.id == chosen.id }) {
    devices[idx] = MicrophoneDevice(id: chosen.id, name: chosen.name, isDefault: true)
}
```

## Prevention/Testing

- Unit tests added for `selectDefaultDevice()` covering: UID match, UID not found (fallback), nil UID (fallback), empty device list
- Tests are pure functions — no TCC permissions or audio hardware required
- Test file: `MuesliTests/MicrophoneManagerTests.swift`

## Related Issues/PRs

- GitHub Issue: #20
- GitHub PR: #21
- Related debug log: `2026-02-17_mic-sample-rate-race.md` (another microphone-related fix)

## Notes

- `AVCaptureDevice.DiscoverySession` ordering should never be relied upon for determining the "default" device — always query Core Audio directly
- The existing `CoreAudioHelpers` infrastructure already had the necessary APIs; no new Core Audio code was needed
- A follow-up enhancement could listen for `kAudioHardwarePropertyDefaultInputDevice` changes to auto-update the selection when the user changes their system default while Muesli is running
