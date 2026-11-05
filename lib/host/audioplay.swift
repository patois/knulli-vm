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

// LATENCY POLICY — read this before changing a number.
//
// Everything scheduled on an AVAudioPlayerNode is rendered LATER, so the depth
// of that queue IS the delay the player hears. The previous policy scheduled
// every buffer immediately and throttled only above 250 ms, which lets the
// queue settle at ~250-300 ms and stay there: the guest produces at exactly
// realtime, so once it is full nothing ever drains it, and every hiccup (an
// arecord overrun, an ssh burst, an output-device switch) adds delay that is
// never given back. Measured on a realtime-paced producer: median 297 ms from
// t=0.5 s to t=7.5 s, dead flat. On a live instrument that is "I press a key a
// fifth of a second before I hear it".
//
// So: hold the queue at TARGET, and when it blows past CEILING, THROW THE
// BACKLOG AWAY instead of playing it. For a monitor path a one-frame click
// costs less than permanent lag, and dropping is the only way delay can ever
// come back down after a stall — a policy that only ever waits can get slower
// over a session but never faster.
//
// TARGET is 2 chunks: enough that one late read cannot glitch the render clock,
// small enough to stay out of the player's way. CEILING is what a hiccup costs
// before it is discarded rather than absorbed.
let chunkFrames = AVAudioFrameCount(rate / 40)          // 25 ms
let target = 2.0 * Double(chunkFrames) / rate           // ~50 ms
let ceiling = max(0.15, 2 * target)
let stdinHandle = FileHandle.standardInput
let debug = ProcessInfo.processInfo.environment["AUDIOPLAY_DEBUG"] != nil
// Queue depth measured, not inferred: a buffer's completion handler fires when
// the render clock finishes it, so schedule->completion wait is the real delay
// the listener experiences. AUDIOPLAY_DEBUG=1 prints it twice a second.
final class Probe {
    let lock = NSLock(); var waits: [Double] = []
    func add(_ w: Double) { lock.lock(); waits.append(w); lock.unlock() }
    func drain() -> [Double] { lock.lock(); defer { lock.unlock() }; let w = waits; waits = []; return w }
}
let probe = Probe()
func elapsed(_ t0: Double) -> Double { ProcessInfo.processInfo.systemUptime - t0 }

var scheduled = 0.0
var drops = 0
var lastTick = -1
let t0 = ProcessInfo.processInfo.systemUptime
while true {
    guard let data = try? stdinHandle.read(upToCount: Int(chunkFrames) * Int(format.streamDescription.pointee.mBytesPerFrame)),
          !data.isEmpty else { break }
    guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { break }
    buf.frameLength = AVAudioFrameCount(data.count / Int(format.streamDescription.pointee.mBytesPerFrame))
    data.withUnsafeBytes { memcpy(buf.int16ChannelData![0], $0.baseAddress, data.count) }
    let sent = Date()
    player.scheduleBuffer(buf, completionHandler: { if debug { probe.add(Date().timeIntervalSince(sent)) } })
    scheduled += Double(buf.frameLength) / rate
    var ahead = scheduled - elapsed(t0)
    if ahead > ceiling {
        // Backlog: the queue holds more than we are willing to render late.
        // Discard it and re-anchor the clock where the listener actually is —
        // otherwise this lag is permanent.
        let stale = ahead
        player.reset()
        player.play()
        drops += 1
        scheduled = elapsed(t0) + target
        ahead = target
        if debug {
            let msg = String(format: "audioplay: backlog %.0f ms over ceiling — %.0f ms of queued audio discarded (drop #%d)\n",
                             stale * 1000, (stale - target) * 1000, drops)
            FileHandle.standardError.write(Data(msg.utf8))
        }
    } else if ahead > target {
        usleep(UInt32((ahead - target) * 1_000_000))
    }
    if debug {
        let now = Int(elapsed(t0) * 2)
        if now != lastTick {
            lastTick = now
            let w = probe.drain().sorted()
            if !w.isEmpty {
                // stderr, and flushed: this is a diagnostic, and stdout is
                // block-buffered when redirected, so a print here vanishes if
                // the process is killed (which is exactly how a measurement of
                // the live pipe came back empty).
                let msg = String(format: "audioplay: t=%.1fs queue median %.0f ms  max %.0f ms  (n=%d, drops %d)\n",
                                 elapsed(t0), w[w.count / 2] * 1000, w.last! * 1000, w.count, drops)
                FileHandle.standardError.write(Data(msg.utf8))
            }
        }
    }
}
// let the render clock drain what's scheduled, then shut down cleanly
while scheduled > elapsed(t0) + 0.02 { usleep(20_000) }
player.stop()
engine.stop()
