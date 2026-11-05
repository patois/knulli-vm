// audiocap — put REAL host audio on stdout as raw S16LE PCM, until killed.
//
//   usage: audiocap [mic|system] [rate=48000] [channels=2] [--secs N]
//
// The mirror of audioplay.swift (which renders the guest's audio here): this
// reads the Mac's own audio and hands it down a pipe so the VM's capture
// devices carry something other than zeros.
//
//   mic     the Mac's default INPUT device — the built-in microphone on a
//           laptop. AVAudioEngine's inputNode, so it follows a default-device
//           switch the same way audioplay follows the output default.
//   system  what the Mac is PLAYING. There is no built-in system-audio tap in
//           CoreAudio, and the alternatives all mean installing a virtual
//           audio driver; the screen-capture input has carried system audio
//           since macOS 12.3, so that is where this comes from.
//
// Neither source touches a USB device: it is all CoreAudio on the Mac's own
// hardware. A USB audio interface plugged into the Mac is reachable only as
// the user's chosen default *input* under `mic`, never under `system`, and no
// host USB device is ever handed to the VM.
//
// Permission is the first thing that fails, so it is checked before anything
// else and reported as an instruction: `mic` needs Microphone access, `system`
// needs Screen Recording, and both are granted to the app that OWNS THE
// TERMINAL running this, not to this binary. A denied capture does not raise —
// the session starts, the callback simply never fires, and an untouched pipe
// reads as a dead cable forever.
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

// --- arguments ---------------------------------------------------------------
func argAfter(_ flag: String) -> String? {
    let argv = CommandLine.arguments
    guard let i = argv.firstIndex(of: flag), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}
var positional: [String] = []
for (n, a) in CommandLine.arguments.enumerated() where n > 0 {
    if a.hasPrefix("--") { continue }
    positional.append(a)
}
let source = positional.count > 0 ? positional[0] : "mic"
let rate = positional.count > 1 ? (Double(positional[1]) ?? 48000) : 48000
let channels = positional.count > 2 ? (Int(positional[2]) ?? 2) : 2
let secs = Double(argAfter("--secs") ?? "") ?? 0

// The guest end (ssh/aplay) dies whenever `knulli-vm feed stop` or the app
// exits; without this the first write to the broken pipe raises SIGPIPE and
// the process vanishes before the EPIPE branch below can say why.
signal(SIGPIPE, SIG_IGN)

func log(_ s: String) { FileHandle.standardError.write(Data("audiocap: \(s)\n".utf8)) }
func die(_ s: String, _ code: Int32 = 1) -> Never { log(s); exit(code) }

guard source == "mic" || source == "system" else {
    die("source must be 'mic' or 'system'", 2)
}

// --- permission gate ---------------------------------------------------------
if source == "system" {
    // Preflight only: requesting access here would pop a dialog on every
    // automated run, and the outcome is the same either way.
    if !CGPreflightScreenCaptureAccess() {
        die("""
        Screen Recording access is not granted — 'system' audio cannot be read.
          System Settings > Privacy & Security > Screen Recording
          The entry to enable is your TERMINAL app (the one running knulli-vm),
          not audiocap; if it is already listed, toggle it off/on and relaunch
          the terminal. Then: knulli-vm feed usb --source system
        """, 3)
    }
}

// --- output target -----------------------------------------------------------
guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate,
                                    channels: AVAudioChannelCount(channels), interleaved: true) else {
    die("audiocap: bad format \(rate)Hz x\(channels)")
}
let bytesPerFrame = Int(outFormat.streamDescription.pointee.mBytesPerFrame)

// --- bounded hand-off to stdout ---------------------------------------------
// stdout is a pipe into ssh into aplay. A slow reader must never stall the
// capture graph, so frames land in a queue capped in seconds and anything
// beyond it is dropped: a stutter is recoverable, a blocked delegate is not.
let queueCap = 0.75
var pending: [Data] = []
var pendingBytes = 0
let lock = NSLock()
let wake = NSCondition()
var delivered = 0.0, droppedBytes = 0

func enqueue(_ d: Data) {
    lock.lock()
    if pendingBytes + d.count > Int(queueCap * rate * Double(bytesPerFrame)) {
        droppedBytes += d.count
        lock.unlock(); return
    }
    pending.append(d); pendingBytes += d.count
    lock.unlock()
    wake.lock(); wake.signal(); wake.unlock()
}

Thread {
    let out = FileHandle.standardOutput
    while true {
        var chunk: Data?
        lock.lock()
        if !pending.isEmpty { chunk = pending.removeFirst(); pendingBytes -= chunk!.count }
        lock.unlock()
        if let c = chunk {
            delivered += Double(c.count) / (rate * Double(bytesPerFrame))
            // write(_:) is the legacy non-throwing variant — a closed pipe
            // on it raises SIGPIPE and kills the process without this message.
            // write(contentsOf:) throws EPIPE instead, so the exit is legible.
            do { try out.write(contentsOf: c) } catch {
                // ssh/aplay is gone. Exit instead of spinning: knulli-vm feed
                // treats an exited feed as stopped.
                die("stdout closed (\(error.localizedDescription)) — stopping")
            }
        } else {
            wake.lock(); wake.wait(until: Date().addingTimeInterval(0.02)); wake.unlock()
        }
    }
}.start()

// --- format conversion -------------------------------------------------------
// Everything arrives as AVAudioPCMBuffer in whatever the hardware produced
// (float32 at the device's nominal rate, usually non-interleaved) and leaves as
// S16LE at the rate the guest's capture stream is configured for. Doing the
// conversion here keeps audio_feed.sh's hw_params matching exact — on a
// loopback cable the two ends share one ring buffer, so a rate mismatch is not
// an error, it is a pitch shift.
final class Sink {
    let target: AVAudioFormat
    var conv: AVAudioConverter?
    var convSrc: AVAudioFormat?
    var warned = false
    init(_ t: AVAudioFormat) { target = t }

    func push(_ buf: AVAudioPCMBuffer) {
        let src = buf.format
        if conv == nil || convSrc?.sampleRate != src.sampleRate
            || convSrc?.channelCount != src.channelCount
            || convSrc?.commonFormat != src.commonFormat {
            guard let c = AVAudioConverter(from: src, to: target) else {
                if !warned { log("no converter \(src.sampleRate)Hz/\(src.channelCount)ch -> \(target.sampleRate)Hz/\(target.channelCount)ch"); warned = true }
                return
            }
            // The property is sampleRateConverterQuality (NSInteger of
            // AVAudioQuality) — there is no ...ConversionAlgorithm member,
            // and this SDK's AVAudioQuality ladder is min/low/medium/high/max
            // with no "fastest". .low: a live feed trades fidelity for
            // latency, and in practice the Mac's own clock is already 48 kHz
            // so this converter usually runs as a passthrough.
            c.sampleRateConverterQuality = AVAudioQuality.low.rawValue
            conv = c; convSrc = src
            log("capturing \(src.sampleRate)Hz x\(src.channelCount) -> \(Int(target.sampleRate))Hz x\(target.channelCount) S16LE")
        }
        let ratio = target.sampleRate / src.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var fed = false
        // The input block is (inNumberOfPackets, outStatus) — the first
        // argument is a packet COUNT, not a status pointer; the status is the
        // second argument and is written through, and there is no out-format
        // argument to fill (the block's return buffer defines the format).
        let st = conv!.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            status.pointee = .haveData
            fed = true
            return buf
        }
        if st == .error {
            if !warned { log("converter error"); warned = true }
            return
        }
        if out.frameLength == 0 { return }
        // int16ChannelData is a TABLE of per-channel pointers; for an
        // interleaved target channel 0 owns the whole block. Rebounding the
        // table itself (int16ChannelData!) copies pointer bytes and emits
        // silence-shaped garbage instead of samples — deref to channel 0.
        guard let ch = out.int16ChannelData?[0] else { return }
        let n = Int(out.frameLength) * bytesPerFrame
        ch.withMemoryRebound(to: UInt8.self, capacity: n) {
            enqueue(Data(bytes: $0, count: n))
        }
    }
}
let sink = Sink(outFormat)

// --- mic: the engine's input node -------------------------------------------
func runMic() -> Never {
    let dev = AVCaptureDevice.default(for: .audio)
    log("input device: \(dev?.localizedName ?? "none")")
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let fmt = input.outputFormat(forBus: 0)
    // A default input device reporting 0 channels means nothing is available
    // or the mic is denied: say so now, because the engine starts happily and
    // then delivers nothing forever.
    if fmt.channelCount == 0 { die("no audio input device (System Settings > Sound > Input)") }
    input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(max(fmt.sampleRate / 40, 128)),
                     format: nil) { buf, _ in sink.push(buf) }
    engine.prepare()
    do { try engine.start() } catch { die("input engine start failed: \(error)") }
    log("capturing the Mac's microphone")
    RunLoop.current.run()
    exit(0)
}

// --- system: the display's audio --------------------------------------------
// SCStream, not AVCaptureScreenInput: the CLT SDK slice of AVFoundation simply
// has no audio members on AVCaptureScreenInput (capturesAudio never made its
// headers), while ScreenCaptureKit exposes the whole audio configuration. The
// CMSampleBuffers SCStream hands back are converted in place below.
//
// Screen Recording permission gates it (checked in the preflight above); a
// denial surfaces here as the getWithCompletionHandler error, which is the
// message that actually names the failing call.
func runSystem() -> Never {
    let sem = DispatchSemaphore(value: 0)
    var content: SCShareableContent?
    var failure: Error?
    SCShareableContent.getWithCompletionHandler { c, e in
        content = c; failure = e; sem.signal()
    }
    // The completion handler is called on an arbitrary queue; blocking this
    // thread before the runloop starts is safe (the callback never needs it).
    sem.wait()
    if let e = failure {
        die("shareable content failed (Screen Recording permission?): \(e.localizedDescription)")
    }
    guard let display = content?.displays.first else { die("no display to capture audio from") }

    let cfg = SCStreamConfiguration()
    cfg.capturesAudio = true
    cfg.sampleRate = Int(rate)          // Int in the Swift overlay, not CMTimeScale
    cfg.channelCount = channels
    cfg.queueDepth = 8
    // Excludes only THIS process's audio (audiocap plays nothing); the guest's
    // returned output comes from audioplay, a different process, so the app
    // CAN hear itself re-amped. knulli-vm feed warns rather than filtering it.
    if #available(macOS 14.0, *) { cfg.excludesCurrentProcessAudio = true }

    let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                          configuration: cfg, delegate: nil)
    let q = DispatchQueue(label: "audiocap.system")
    do {
        try stream.addStreamOutput(CaptureSink(sink), type: .audio, sampleHandlerQueue: q)
    } catch { die("cannot attach an audio stream output: \(error.localizedDescription)") }

    let startSem = DispatchSemaphore(value: 0)
    var startErr: Error?
    Task {
        do { try await stream.startCapture() } catch { startErr = error }
        startSem.signal()
    }
    startSem.wait()
    if let e = startErr { die("startCapture failed: \(e.localizedDescription)") }
    log("capturing the Mac's system audio from display \(display.displayID)")
    RunLoop.current.run()
    exit(0)
}

// SCStream's sample-buffer delegate: CMSampleBuffer -> AVAudioPCMBuffer ->
// the shared Sink, which does the S16LE/rate/channel work.
final class CaptureSink: NSObject, SCStreamOutput {
    let sink: Sink
    init(_ s: Sink) { sink = s }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let fd = sb.formatDescription else { return }
        // Non-optional in this SDK's overlay (it can't fail — it just wraps
        // the CASSBD, validity shows up when the buffer is built).
        let src = AVAudioFormat(cmAudioFormatDescription: fd)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: frames) else { return }
        // Two-call dance (the Swift overlay returns the OSStatus, not a
        // pointer): first call asks for the size, second fills our storage.
        var size = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: nil)
        guard size > 0 else { return }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { storage.deallocate() }
        let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil,
            bufferListOut: storage.assumingMemoryBound(to: AudioBufferList.self),
            bufferListSize: size,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: nil)
        guard st == noErr else { return }
        let abl = storage.assumingMemoryBound(to: AudioBufferList.self)
        // Both lists were built from the same format description, so copying
        // buffer-by-buffer is layout-correct for interleaved and planar alike.
        buf.frameLength = frames
        let dst = buf.mutableAudioBufferList
        let n = min(Int(abl.pointee.mNumberBuffers), Int(dst.pointee.mNumberBuffers))
        // mBuffers imports as a single AudioBuffer (the C array's first
        // element), so it cannot be indexed dynamically — take its offset and
        // index from there (the standard AudioBufferList idiom).
        let off = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers)!
        let sbuf = UnsafeMutableRawPointer(abl).advanced(by: off)
                                .assumingMemoryBound(to: AudioBuffer.self)
        let dbuf = UnsafeMutableRawPointer(dst).advanced(by: off)
                                .assumingMemoryBound(to: AudioBuffer.self)
        for i in 0..<n {
            let s = sbuf[i], d = dbuf[i]
            let bytes = Int(min(s.mDataByteSize, d.mDataByteSize))
            if let sp = s.mData, let dp = d.mData { memcpy(dp, sp, bytes) }
        }
        sink.push(buf)
    }
}

if secs > 0 {
    DispatchQueue.global().asyncAfter(deadline: .now() + secs) {
        log("held out \(String(format: "%.1f", delivered))s of audio, dropped \(droppedBytes) bytes")
        exit(0)
    }
}
log("source=\(source) target=\(Int(rate))Hz x\(channels) S16LE")
if source == "mic" { runMic() } else { runSystem() }
