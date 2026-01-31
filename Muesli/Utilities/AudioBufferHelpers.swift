import AVFoundation
import CoreMedia

/// Audio buffer conversion utilities (extracted from EchoCancellationService)
enum AudioBufferHelpers {
    /// Extract Float32 samples from CMSampleBuffer at original sample rate
    /// - Parameter sampleBuffer: The audio sample buffer
    /// - Returns: Mono Float32 samples, or nil if extraction fails
    static func extractSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }
        
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )
        
        guard status == kCMBlockBufferNoErr, let data = dataPointer else {
            return nil
        }
        
        // Get format info to determine channel count
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        
        let channelCount = Int(asbd.pointee.mChannelsPerFrame)
        let bitsPerChannel = Int(asbd.pointee.mBitsPerChannel)
        let formatFlags = asbd.pointee.mFormatFlags
        let isFloat = (formatFlags & kAudioFormatFlagIsFloat) != 0
        
        // Convert bytes to Float32 samples
        let floatCount = length / MemoryLayout<Float>.size
        let floatPointer = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: floatCount)
        
        if channelCount == 2 && isFloat && bitsPerChannel == 32 {
            // Stereo Float32: convert to mono by averaging
            let frameCount = floatCount / 2
            var monoSamples: [Float] = []
            monoSamples.reserveCapacity(frameCount)
            for i in 0..<frameCount {
                let left = floatPointer[i * 2]
                let right = floatPointer[i * 2 + 1]
                monoSamples.append((left + right) / 2.0)
            }
            return monoSamples
        } else if channelCount == 1 && isFloat && bitsPerChannel == 32 {
            // Mono Float32: return as-is
            return Array(UnsafeBufferPointer(start: floatPointer, count: floatCount))
        }
        
        // Unsupported format
        return nil
    }
    
    /// Create CMSampleBuffer from Float32 samples
    /// Converts from mono Float32 to stereo Float32 (optional resample) for file output
    /// - Parameters:
    ///   - samples: Float32 mono samples at source sample rate
    ///   - timestamp: Presentation timestamp for the buffer
    ///   - sourceSampleRate: Source sample rate (default: 48000)
    ///   - targetSampleRate: Target sample rate (default: 48000)
    /// - Returns: CMSampleBuffer in Float32 stereo format, or nil if conversion fails
    static func createSampleBuffer(
        from samples: [Float],
        timestamp: CMTime,
        sourceSampleRate: Int = 48000,
        targetSampleRate: Int = 48000
    ) -> CMSampleBuffer? {
        guard !samples.isEmpty else { return nil }
        
        // 1. Resample from sourceSampleRate to targetSampleRate (if needed)
        let resampled = resampleFloat32(
            samples: samples,
            sourceSampleRate: sourceSampleRate,
            targetSampleRate: targetSampleRate
        )
        
        guard !resampled.isEmpty else { return nil }
        
        // 2. Convert mono Float32 to stereo Float32 (duplicate channel)
        let stereoFloat32: [Float] = resampled.flatMap { sample in
            [sample, sample]
        }
        
        // 3. Create AudioStreamBasicDescription for Float32 stereo
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(targetSampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,  // 4 bytes per sample * 2 channels
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        
        // 4. Create format description
        var formatDesc: CMFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: nil,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        
        guard status == noErr, let format = formatDesc else {
            return nil
        }
        
        // 5. Create block buffer with the stereo Float32 data
        let dataSize = stereoFloat32.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        
        guard status == noErr, let blockBuf = blockBuffer else {
            return nil
        }
        
        // 6. Copy stereo Float32 data to block buffer
        status = stereoFloat32.withUnsafeBufferPointer { bufferPtr in
            CMBlockBufferReplaceDataBytes(
                with: bufferPtr.baseAddress!,
                blockBuffer: blockBuf,
                offsetIntoDestination: 0,
                dataLength: dataSize
            )
        }
        
        guard status == noErr else {
            return nil
        }
        
        // 7. Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        let sampleCount = resampled.count
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(targetSampleRate)),
            presentationTimeStamp: timestamp,
            decodeTimeStamp: CMTime.invalid
        )
        
        status = CMSampleBufferCreate(
            allocator: nil,
            dataBuffer: blockBuf,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: sampleCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        
        return (status == noErr) ? sampleBuffer : nil
    }
    
    /// Simple resampling using linear interpolation
    /// - Parameters:
    ///   - samples: Input samples
    ///   - sourceSampleRate: Source sample rate
    ///   - targetSampleRate: Target sample rate
    /// - Returns: Resampled samples
    static func resampleFloat32(
        samples: [Float],
        sourceSampleRate: Int,
        targetSampleRate: Int
    ) -> [Float] {
        guard sourceSampleRate != targetSampleRate else { return samples }
        guard !samples.isEmpty else { return [] }
        
        let ratio = Double(sourceSampleRate) / Double(targetSampleRate)
        let outputCount = Int(Double(samples.count) / ratio)
        
        guard outputCount > 0 else { return [] }
        
        var output = [Float](repeating: 0, count: outputCount)
        
        for i in 0..<outputCount {
            let sourceIndex = Double(i) * ratio
            let lowerIndex = Int(sourceIndex)
            let upperIndex = min(lowerIndex + 1, samples.count - 1)
            let fraction = Float(sourceIndex - Double(lowerIndex))
            
            // Linear interpolation
            output[i] = samples[lowerIndex] * (1.0 - fraction) + samples[upperIndex] * fraction
        }
        
        return output
    }
}
