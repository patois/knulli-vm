// audioplay — play raw S16LE PCM from stdin through CoreAudio.
// usage: audioplay [rate=48000] [channels=2]
//
// The original AudioQueue implementation *reported success but rendered
// nothing*: it exited 0 with the output device never entering the
// running state (verified via kAudioDevicePropertyDeviceIsRunningSomewhere
// — afplay flips it, audioplay didn't). AVAudioEngine + AVAudioPlayerNode
// is the straightforward modern path and renders to the current default
// output device, following default-device switches automatically.
import AVFoundation
import Foundation

let rate = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 48000) : 48000
let chan = CommandLine.arguments.count > 2 ? (UInt32(CommandLine.arguments[2]) ?? 2) : 2
guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate,
                                 channels: chan, interleaved: true) else {
    FileHandle.standardError.write(Data("audioplay: bad format \(rate)Hz x\(chan)\n".utf8)); exit(1)
}

let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: format)
engine.mainMixerNode.outputVolume = 1.0
do {
    try engine.start()
} catch {
    FileHandle.standardError.write(Data("audioplay: engine start failed: \(error)\n".utf8)); exit(1)
}
player.play()

// One buffer per 25 ms of audio; keep at most ~250 ms of material
// scheduled ahead of the render clock (bounded latency and memory even
// when stdin is a file rather than a paced pipe).
let chunkFrames = AVAudioFrameCount(rate / 40)
let stdinHandle = FileHandle.standardInput
var scheduled = 0.0
let t0 = ProcessInfo.processInfo.systemUptime
while true {
    guard let data = try? stdinHandle.read(upToCount: Int(chunkFrames) * Int(format.streamDescription.pointee.mBytesPerFrame)),
          !data.isEmpty else { break }
    guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { break }
    buf.frameLength = AVAudioFrameCount(data.count / Int(format.streamDescription.pointee.mBytesPerFrame))
    data.withUnsafeBytes { memcpy(buf.int16ChannelData![0], $0.baseAddress, data.count) }
    player.scheduleBuffer(buf, completionHandler: nil)
    scheduled += Double(buf.frameLength) / rate
    let ahead = scheduled - (ProcessInfo.processInfo.systemUptime - t0)
    if ahead > 0.25 { usleep(UInt32(min(ahead - 0.25, 0.25) * 1_000_000)) }
}
// let the render clock drain what's scheduled, then shut down cleanly
while scheduled > (ProcessInfo.processInfo.systemUptime - t0) + 0.02 { usleep(20_000) }
player.stop()
engine.stop()
