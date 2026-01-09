# Alternative Transcription Backend Research

**Date:** January 8, 2026  
**Context:** Investigating alternatives to WhisperKit for Muesli's transcription backend

---

## Executive Summary

| Option | Viable? | Cost | Notes |
|--------|---------|------|-------|
| **WhisperKit (current)** | ✅ Yes | Free | Best option for local-first philosophy |
| **Apple SFSpeechRecognizer** | ⚠️ Partial | Free | Good fallback, has limitations |
| **Wispr Flow API** | ❌ No | Extra $$ | Separate usage-based billing from Pro subscription |
| **Wispr Flow Desktop App** | ❌ No | N/A | Designed for dictation, not transcription |

**Recommendation:** Stay with WhisperKit. Optionally add Apple's SFSpeechRecognizer as a streaming fallback.

---

## Option 1: Wispr Flow API

### What It Offers
- WebSocket API for real-time streaming transcription
- REST API for batch processing
- Advanced features: auto-edits, filler word removal, context-aware transcription
- 100+ language support
- Audio format: 16kHz, mono, 16-bit PCM WAV (same as WhisperKit)

### API Access
- Developer Platform: [platform.wisprflow.ai](https://platform.wisprflow.ai)
- Requires organization setup and approval
- API keys generated in Developer Platform

### Pricing Discovery
**The API is NOT included in Wispr Flow Pro subscription.**

- Pro subscription ($8-10/month): Unlimited use of *their app* only
- API: Separate usage-based billing (charged per token)
- Requires adding payment method in Developer Platform
- Organization/business-oriented product

From their docs:
> "All models are charged based on usage tokens. To use the API, you need to add a payment method in the Developer Platform's Billing section."

### Verdict
❌ **Not recommended** — Would add ongoing costs and cloud dependency, contrary to Muesli's local-first philosophy.

---

## Option 2: Wispr Flow Desktop App (Piggybacking)

### How Wispr Flow Works
Wispr Flow is a **dictation** tool, not a transcription tool:

| Dictation (Wispr Flow) | Transcription (Muesli) |
|------------------------|------------------------|
| Your voice → text | Meeting audio → text |
| Microphone input only | System audio capture |
| Inserts at cursor | Saves to file |
| Hotkey-triggered (Fn) | Continuous recording |
| Interactive | Background capture |

### Why Piggybacking Won't Work
1. **No external audio input**: Only listens to microphone, not system audio
2. **No automation interface**: No AppleScript, XPC, URL schemes, or Shortcuts support
3. **Designed for insertion**: Types at cursor, can't redirect output
4. **No audio routing**: Can't pipe ScreenCaptureKit audio into it

### Verdict
❌ **Not possible** — Wispr Flow is architecturally designed for personal dictation, not meeting transcription.

---

## Option 3: Apple SFSpeechRecognizer

### What It Offers
- Native macOS Speech framework
- Real-time streaming transcription
- On-device processing available (`requiresOnDeviceRecognition = true`)
- Cloud processing for better accuracy (Apple's servers)
- No third-party dependencies

### Integration Approach
```swift
import Speech

let recognizer = SFSpeechRecognizer()
let request = SFSpeechAudioBufferRecognitionRequest()
request.shouldReportPartialResults = true
// request.requiresOnDeviceRecognition = true  // For offline mode

let task = recognizer?.recognitionTask(with: request) { result, error in
    if let result = result {
        let text = result.bestTranscription.formattedString
        // Handle transcription...
    }
}

// Feed audio buffers:
// request.append(audioBuffer)
```

### Limitations
| Limitation | Details |
|------------|---------|
| **~1 minute timeout** | Each recognition task times out; must restart periodically |
| **Rate limiting** | Apple throttles heavy usage (exact limits undocumented) |
| **On-device accuracy** | Lower than cloud or WhisperKit |
| **Single stream** | Would need custom Me/Them handling |

### Workaround for Continuous Recording
Restart recognition task every ~50 seconds before timeout:
```swift
// When task ends or times out:
recognitionTask?.cancel()
audioEngine.inputNode.removeTap(onBus: 0)
// Brief delay then restart
DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
    startRecognitionTask()
}
```

### Verdict
⚠️ **Viable as fallback** — Good for streaming/low-latency when online, but requires restart logic and has lower accuracy than WhisperKit.

---

## Option 4: WhisperKit (Current Implementation)

### What It Offers
- Fully local, on-device processing
- State-of-the-art Whisper models
- No usage limits or rate throttling
- No ongoing costs
- Excellent accuracy

### Current Implementation
- 5-second audio chunks with 1.5-second overlap
- Separate streams for system audio (Them) and microphone (Me)
- Voice Activity Detection to skip silence
- High-quality resampling via AVAudioConverter

### Trade-offs
| Pros | Cons |
|------|------|
| Free | Requires model download (~150MB-1GB) |
| Private | 5-second chunked latency |
| Offline capable | No auto-edits or filler removal |
| Excellent accuracy | More CPU/Neural Engine usage |

### Verdict
✅ **Best option** — Aligns with Muesli's local-first philosophy, already implemented, no ongoing costs.

---

## Comparison Matrix

| Feature | WhisperKit | Apple Speech | Wispr API | Wispr App |
|---------|------------|--------------|-----------|-----------|
| **Local processing** | ✅ Fully | ⚠️ Optional | ❌ Cloud | N/A |
| **Cost** | Free | Free | Per-token | N/A |
| **Latency** | ~5s chunks | Streaming | Streaming | N/A |
| **Accuracy** | Excellent | Good | Excellent | N/A |
| **Offline** | ✅ Yes | ⚠️ Limited | ❌ No | N/A |
| **Me/Them streams** | ✅ Built-in | Manual | Manual | N/A |
| **Auto-edits** | ❌ No | ❌ No | ✅ Yes | N/A |
| **Filler removal** | ❌ No | ❌ No | ✅ Yes | N/A |
| **Rate limits** | None | Yes | Usage-based | N/A |
| **Setup required** | Model download | Permissions | API key + billing | N/A |

---

## Recommendations

### Primary: Keep WhisperKit
WhisperKit remains the best choice for Muesli because:
1. Fully local (matches "local-first" philosophy)
2. No ongoing costs
3. Excellent accuracy
4. Already integrated and working
5. No rate limits or throttling

### Optional Enhancement: Add Apple Speech as Fallback
Could be useful when:
- User hasn't downloaded a WhisperKit model yet
- User wants lower-latency streaming results
- As a quick-start before model download completes

Implementation would require:
- Transcription backend selector in preferences
- Restart logic for 1-minute timeout
- Graceful fallback on rate limiting

### Not Recommended
- **Wispr Flow API**: Extra costs, cloud dependency
- **Wispr Flow App Integration**: Not technically possible

---

## References

- [Wispr Flow API Docs](https://api-docs.wisprflow.ai/)
- [Wispr Flow Pricing](https://wisprflow.ai/pricing)
- [Wispr Flow Usage & Billing](https://api-docs.wisprflow.ai/usage_billing)
- [Apple Speech Framework](https://developer.apple.com/documentation/speech)
- [WhisperKit GitHub](https://github.com/argmaxinc/WhisperKit)
