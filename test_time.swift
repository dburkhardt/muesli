import AVFoundation
import CoreAudio

let hostTime = mach_absolute_time()
let avTime = AVAudioTime.seconds(forHostTime: hostTime)
let caTime = CACurrentMediaTime()
print("avTime: \(avTime), caTime: \(caTime)")
