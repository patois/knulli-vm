// audioplay — play raw S16LE PCM from stdin through CoreAudio (AudioQueue).
// usage: audioplay [rate=48000] [channels=2]
import Foundation
import AudioToolbox

let rate = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 48000) : 48000
let channels = UInt32(CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 2) : 2)
let frameBytes = 2 * Int(channels)

var asbd = AudioStreamBasicDescription(
    mSampleRate: rate,
    mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: AudioFormatFlags(kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked),
    mBytesPerPacket: UInt32(frameBytes),
    mFramesPerPacket: 1,
    mBytesPerFrame: UInt32(frameBytes),
    mChannelsPerFrame: channels,
    mBitsPerChannel: 16,
    mReserved: 0)

var queue: AudioQueueRef?
let status = AudioQueueNewOutput(&asbd, { _, _, _ in }, nil, nil, nil, 0, &queue)
guard status == noErr, let q = queue else {
    FileHandle.standardError.write(Data("audioplay: AudioQueueNewOutput failed (\(status))\n".utf8))
    exit(1)
}
AudioQueueStart(q, nil)

let chunk = frameBytes * Int(rate) / 10          // 100 ms
let stdinHandle = FileHandle.standardInput
while let data = try? stdinHandle.read(upToCount: chunk), !data.isEmpty {
    var buf: AudioQueueBufferRef?
    guard AudioQueueAllocateBuffer(q, UInt32(data.count), &buf) == noErr, let b = buf else { break }
    _ = data.withUnsafeBytes { memcpy(b.pointee.mAudioData, $0.baseAddress, data.count) }
    AudioQueueEnqueueBuffer(q, b, 0, nil)
}
// drain remaining queued audio (~4 buffer depths) before exiting
usleep(600_000)
AudioQueueStop(q, true)
AudioQueueDispose(q, true)
