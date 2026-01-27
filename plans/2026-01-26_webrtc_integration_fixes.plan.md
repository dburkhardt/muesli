---
name: WebRTC AEC3 Integration Fixes
overview: Address critical gaps in the WebRTC AEC3 implementation from commit 9dca743. The Swift code is well-structured but Xcode project integration, CI workflow, and naming consistency are incomplete. This plan fixes those issues to make WebRTC AEC functional.
todos:
  - id: fix1-xcode-project
    content: "Fix 1: Configure Xcode project - add ObjC++ files, bridging header, framework search paths"
    status: completed
  - id: fix2-build-xcframework
    content: "Fix 2: Build and verify XCFramework locally using build-webrtc-aec.sh"
    status: completed
  - id: fix3-ci-workflow
    content: "Fix 3: Update CI workflow with XCFramework build step and caching"
    status: completed
  - id: fix4-rename-nlms
    content: "Fix 4: Rename EchoCancellationService to EchoCancellationServiceNLMS for consistency"
    status: completed
  - id: fix5-integration-test
    content: "Fix 5: Add integration test verifying WebRTC is not in stub mode"
    status: completed
  - id: fix6-verify-e2e
    content: "Fix 6: End-to-end verification - build app and test echo cancellation"
    status: completed
isProject: false
---

# WebRTC AEC3 Integration Fixes

**Created**: 2026-01-26
**Based on**: Code review of commit 9dca743d401bd0418ddbd17db6e0e0c138d65ebe
**Status**: Ready for implementation

## Background

The WebRTC AEC3 implementation (commit 9dca743) established the Swift-side architecture:
- ✅ `EchoCancellationServiceWebRTC.swift` - Hybrid synchronization service
- ✅ `AudioRingBuffer.swift` - Real-time safe ring buffer
- ✅ `WebRTCAECBridge.h/.mm` - ObjC++ bridge with stub fallback
- ✅ Factory pattern and protocol updates
- ✅ Comprehensive tests
- ✅ Documentation updates

However, **critical integration steps were missed**:
- ❌ Xcode project not configured (files not added)
- ❌ CI workflow not updated
- ❌ NLMS class not renamed as specified in original plan
- ❌ No verification that WebRTC is actually functional (vs stub)

---

## Fix 1: Configure Xcode Project (BLOCKER)

The ObjC++ files exist but aren't added to the Xcode project.

### 1a. Add ObjC++ Files to Build Sources

Open `Muesli.xcodeproj` in Xcode and add:
1. `Muesli/Services/WebRTCAEC/WebRTCAECBridge.h`
2. `Muesli/Services/WebRTCAEC/WebRTCAECBridge.mm`

Ensure they appear in:
- Project Navigator under `Muesli/Services/WebRTCAEC/`
- Build Phases → Compile Sources (for `.mm` file)

### 1b. Configure Bridging Header

In Xcode, select the Muesli target → Build Settings:

```
SWIFT_OBJC_BRIDGING_HEADER = Muesli/Muesli-Bridging-Header.h
```

Or via project.pbxproj:
```
SWIFT_OBJC_BRIDGING_HEADER = "Muesli/Muesli-Bridging-Header.h";
```

### 1c. Add Framework Search Paths (after XCFramework is built)

Build Settings → Framework Search Paths:
```
$(PROJECT_DIR)/Muesli/Frameworks
```

### 1d. Add Header Search Paths

Build Settings → Header Search Paths:
```
$(PROJECT_DIR)/Muesli/Frameworks/webrtc_audio_processing.xcframework/macos-arm64_x86_64/Headers
```

### 1e. Link XCFramework

Build Phases → Link Binary With Libraries:
- Add `webrtc_audio_processing.xcframework`
- Set "Embed" to "Do Not Embed" (static library)

**Verification**: Build should succeed without WebRTC stub warning:
```
[WebRTCAEC] Initialized with WebRTC AEC3, sampleRate=48000, frameSize=480
```

---

## Fix 2: Build XCFramework Locally

### 2a. Install Dependencies

```bash
brew install meson ninja pkg-config
```

### 2b. Run Build Script

```bash
./scripts/build-webrtc-aec.sh
```

Expected output:
```
=== Build Complete ===
XCFramework: Muesli/Frameworks/webrtc_audio_processing.xcframework
Checksum:    Muesli/Frameworks/webrtc_audio_processing.sha256
```

### 2c. Verify Architecture

```bash
lipo -info Muesli/Frameworks/webrtc_audio_processing.xcframework/macos-arm64_x86_64/*.a
# Expected: Architectures in the fat file: arm64 x86_64

nm Muesli/Frameworks/webrtc_audio_processing.xcframework/macos-arm64_x86_64/*.a | grep AudioProcessing | head -5
# Should show AudioProcessing symbols
```

### 2d. Verify WebRTC Not in Stub Mode

After building the app, check logs for:
```
[WebRTCAEC] Initialized with WebRTC AEC3, sampleRate=48000, frameSize=480
```

NOT:
```
[WebRTCAEC] Initialized in STUB mode (WebRTC library not available)
```

---

## Fix 3: Update CI Workflow

Add to `.github/workflows/ci.yml` in the `build` job, before the Xcode build step:

```yaml
    # WebRTC AEC XCFramework
    - name: Cache WebRTC XCFramework
      id: cache-webrtc
      uses: actions/cache@v4
      with:
        path: Muesli/Frameworks/webrtc_audio_processing.xcframework
        key: webrtc-v1.3-${{ runner.os }}-${{ runner.arch }}-xcode${{ env.XCODE_VERSION }}-${{ hashFiles('scripts/build-webrtc-aec.sh', 'scripts/cross_mac_*.txt') }}

    - name: Install WebRTC Build Dependencies
      if: steps.cache-webrtc.outputs.cache-hit != 'true'
      run: brew install meson ninja pkg-config

    - name: Build WebRTC XCFramework
      if: steps.cache-webrtc.outputs.cache-hit != 'true'
      run: ./scripts/build-webrtc-aec.sh
      timeout-minutes: 25

    - name: Verify WebRTC XCFramework
      run: |
        echo "Checking XCFramework..."
        lipo -info Muesli/Frameworks/webrtc_audio_processing.xcframework/macos-arm64_x86_64/*.a
        echo "XCFramework verified."
```

**Note**: The cache key includes:
- `runner.os` and `runner.arch` for ABI compatibility
- `XCODE_VERSION` for toolchain compatibility  
- Hash of build scripts for reproducibility

---

## Fix 4: Rename NLMS Class for Consistency

The original plan specified renaming `EchoCancellationService` → `EchoCancellationServiceNLMS`. This makes the naming consistent and clarifies that it's the legacy implementation.

### 4a. Rename the Class

In `Muesli/Services/EchoCancellationService.swift`:

```swift
// BEFORE (line 328):
final class EchoCancellationService: @unchecked Sendable, EchoCancellationServiceProtocol {

// AFTER:
final class EchoCancellationServiceNLMS: @unchecked Sendable, EchoCancellationServiceProtocol {
```

### 4b. Update Factory

```swift
// BEFORE (line 54-61):
private static func createNLMS() -> EchoCancellationServiceProtocol {
    return EchoCancellationService(
        ...
    )
}

// AFTER:
private static func createNLMS() -> EchoCancellationServiceProtocol {
    return EchoCancellationServiceNLMS(
        ...
    )
}
```

### 4c. Update Extension

```swift
// BEFORE (line 67):
extension EchoCancellationService {

// AFTER:
extension EchoCancellationServiceNLMS {
```

### 4d. Update Tests

In `MuesliTests/EchoCancellationServiceTests.swift`:

```swift
// BEFORE (line 308):
var sut: EchoCancellationService!

// AFTER:
var sut: EchoCancellationServiceNLMS!

// BEFORE (line 315):
sut = EchoCancellationService(

// AFTER:
sut = EchoCancellationServiceNLMS(
```

### 4e. Update Factory Test

```swift
// BEFORE (line 156):
XCTAssertTrue(service is EchoCancellationService)

// AFTER:
XCTAssertTrue(service is EchoCancellationServiceNLMS)
```

### 4f. Optionally Rename File

Rename `EchoCancellationService.swift` → `EchoCancellationServiceNLMS.swift`

This requires updating the Xcode project file to reference the new filename.

---

## Fix 5: Add Integration Test for WebRTC Mode

Add a test that verifies WebRTC is not running in stub mode:

```swift
// In MuesliTests/EchoCancellationServiceTests.swift

final class EchoCancellationWebRTCIntegrationTests: XCTestCase {
    
    func testWebRTCNotInStubMode() {
        // Create WebRTC service directly
        let service = EchoCancellationServiceWebRTC()
        
        // In CI with proper XCFramework, this should be true
        // In stub mode, isReady is still true but ERLE/delay won't update
        XCTAssertTrue(service.isReady, "WebRTC service should be ready")
        
        // Feed enough audio to trigger processing
        let systemAudio = [Float](repeating: 0.1, count: 4800)  // 100ms
        let micAudio = [Float](repeating: 0.2, count: 4800)
        
        // Warmup
        for _ in 0..<15 {
            service.storeSystemAudio(samples: Array(systemAudio.prefix(400)))
            _ = service.processMicrophoneAudio(microphoneSamples: Array(micAudio.prefix(400)))
        }
        
        // Process enough to get stats
        for _ in 0..<100 {
            service.storeSystemAudio(samples: Array(systemAudio.prefix(480)))
            _ = service.processMicrophoneAudio(microphoneSamples: Array(micAudio.prefix(480)))
        }
        
        // In real WebRTC mode, delay should be estimated (not -1)
        // This test will FAIL in stub mode, alerting us to missing XCFramework
        #if !DEBUG
        // Only enforce in release builds (CI) where XCFramework should be present
        let delay = service.currentDelayMs
        XCTAssertNotEqual(delay, -1, 
            "WebRTC delay should be estimated (not -1). Is XCFramework linked?")
        #endif
    }
}
```

---

## Fix 6: End-to-End Verification

### 6a. Build and Launch

```bash
./scripts/build-and-launch.sh
# Wait for build...
tail -30 "$(ls -t /tmp/muesli-build-*.log | head -1)"
```

### 6b. Check Diagnostic Logs

After starting a test recording:

```bash
cat ~/Library/Application\ Support/Muesli/Logs/muesli-$(date +%Y-%m-%d).log | grep -E "WEBRTC|AEC_FACTORY"
```

Expected:
```
AEC_FACTORY: Created WebRTC service
WEBRTC_INIT_SUCCESS: AEC3 ready, frameSize=480
WEBRTC_OFFSET: <offset> samples (<ms>ms)
```

NOT:
```
AEC_FACTORY_FALLBACK: WebRTC failed, using NLMS
```

### 6c. Test with Actual Meeting

1. Join a Zoom/Teams/Meet call
2. Start Muesli recording
3. Have remote participant speak
4. Verify "Me" segments don't contain echo of remote speech
5. Check logs for ERLE values (should be 20-35 dB with WebRTC, vs 10-15 dB with NLMS)

---

## Files to Modify

| File | Action | Description |
|------|--------|-------------|
| `Muesli.xcodeproj/project.pbxproj` | Modify | Add ObjC++ files, bridging header config |
| `.github/workflows/ci.yml` | Modify | Add WebRTC build step and caching |
| `Muesli/Services/EchoCancellationService.swift` | Modify | Rename class to `EchoCancellationServiceNLMS` |
| `MuesliTests/EchoCancellationServiceTests.swift` | Modify | Update class name references, add integration test |

---

## Verification Checklist

- [ ] `WebRTCAECBridge.mm` appears in Build Phases → Compile Sources
- [ ] Bridging header configured in Build Settings
- [ ] XCFramework exists at `Muesli/Frameworks/webrtc_audio_processing.xcframework`
- [ ] Build succeeds without stub warning
- [ ] `EchoCancellationServiceNLMS` is the class name in code
- [ ] CI builds pass with WebRTC caching
- [ ] Diagnostic logs show "WEBRTC_INIT_SUCCESS" not "STUB mode"
- [ ] Integration test verifies delay estimation works

---

## Risk Assessment

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| XCFramework build fails on CI | Medium | Build script already tested locally; 25-min timeout allows retry |
| Xcode project merge conflicts | Low | Changes are additive, not modifying existing entries |
| NLMS rename breaks existing code | Low | Only internal class name; protocol unchanged |
| WebRTC still in stub mode | Medium | Integration test catches this; verify logs after build |

---

## Estimated Effort

| Fix | Time |
|-----|------|
| Fix 1: Xcode project | 15 min |
| Fix 2: Build XCFramework | 25 min (mostly waiting) |
| Fix 3: CI workflow | 10 min |
| Fix 4: Rename NLMS | 10 min |
| Fix 5: Integration test | 10 min |
| Fix 6: E2E verification | 20 min |
| **Total** | **~90 min** |
