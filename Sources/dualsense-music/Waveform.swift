import Foundation
import IOKit.hid

/// Bluetooth reports that play a raw waveform on the DualSense's two actuators
/// (3000 Hz, signed 8-bit, left/right interleaved). Packet grammar from egormanga's
/// SAxense research: https://apps.sdore.me/SAxense
enum WaveReport {
    /// Stereo frames per report. macOS sends one 83-byte Bluetooth packet per sniff interval
    /// (7.5 ms in Game Mode), so report 0x32 (142 bytes, two packets, 15 ms) must carry more
    /// than 15 ms of sound: 62 frames = 20.7 ms is the most that fits beside the header.
    static let frames = 62
    static let size = 142

    static func crc32(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in bytes { c ^= UInt32(b); for _ in 0..<8 { c = (c >> 1) ^ (0xEDB88320 & (0 &- (c & 1))) } }
        return ~c
    }

    /// Fill the trailing CRC; Bluetooth output reports are checksummed with a 0xA2 prefix.
    static func seal(_ r: inout [UInt8]) {
        let c = crc32([0xA2] + r.dropLast(4))
        for k in 0..<4 { r[r.count - 4 + k] = UInt8((c >> (8 * UInt32(k))) & 0xFF) }
    }

    /// One audio report: session header (packet 0x11) + one double-length sample packet (0x12).
    /// Two sample packets in one report hang the controller; other lengths are ignored.
    static func audio(seq: UInt8, counter: UInt8, samples: [Int8]) -> [UInt8] {
        precondition(samples.count == frames * 2)
        var r = [UInt8](repeating: 0, count: size)
        r[0] = 0x32; r[1] = (seq & 0x0F) << 4
        r[2] = 0x91; r[3] = 7; r[4] = 0xFE; r[9] = 64 /* controller-side buffer */; r[10] = counter
        r[11] = 0xD2; r[12] = UInt8(frames)   // 0x12 | sized | "length is doubled"
        for (i, s) in samples.enumerated() { r[13 + i] = UInt8(bitPattern: s) }
        seal(&r)
        return r
    }

    /// Sent once: state packet (0x10) with the audio volumes up and rumble emulation off,
    /// without which the actuators stay silent. Bytes as in awalol/dualsense-bt-haptics;
    /// side effect: the light bar turns yellow.
    static func setup() -> [UInt8] {
        var r = [UInt8](repeating: 0, count: size)
        r[0] = 0x32; r[1] = 0x10
        let p: [UInt8] = [0x90, 0x3F, 0xFD, 0xF7, 0, 0, 0x7F, 0x7F, 0xFF, 0x09, 0, 0x0F]
            + [UInt8](repeating: 0, count: 27) + [0x0A, 0x07, 0, 0, 0x02, 0x01, 0x00, 0xFF, 0xD7, 0x00]
        r.replaceSubrange(2..<2 + p.count, with: p)
        seal(&r)
        return r
    }
}

/// Turns captured sound into 3 kHz actuator samples made to be felt, not heard:
/// left = the real bass wave (below ~150 Hz, which skin feels directly);
/// right = a 200 Hz buzz whose strength follows the voice/melody band (300 Hz and up), because
/// skin cannot feel those pitches and the actuator would only play them as a tinny speaker.
struct Decimator {
    var gain: Float
    private var low: Float = 0, low2: Float = 0, mid: Float = 0, mid2: Float = 0, env: Float = 0, sumLow: Float = 0, n = 0
    private var peakLow: Float = 0, peakEnv: Float = 0, phase: Float = 0
    init(gain: Float) { self.gain = gain }

    mutating func process(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Float, into out: inout [Int8]) {
        func pole(_ hz: Float) -> Float { 1 - expf(-2 * Float.pi * hz / sampleRate) }
        func time(_ s: Float) -> Float { 1 - expf(-1 / (s * sampleRate)) }
        let step = max(1, Int(sampleRate / 3000))
        let aLow = pole(150), aMid = pole(300), attack = time(0.003), release = time(0.02)
        let decay = expf(-Float(step) / (5 * sampleRate))   // loudness reference fades over ~5 s
        for i in 0..<count {
            let x = samples[i]
            low += aLow * (x - low); low2 += aLow * (low - low2)   // two stages keep voices out of the bass hand
            mid += aMid * (x - mid)
            let h = x - mid; mid2 += aMid * (h - mid2)       // two high-pass stages keep bass out of the voice hand
            let v = abs(h - mid2)                            // voice/melody band, rectified
            env += (v > env ? attack : release) * (v - env)  // fast up, 20 ms down: gaps stay gaps
            sumLow += low2; n += 1
            guard n == step else { continue }
            let l = sumLow / Float(step)                     // block mean = low-pass before 3 kHz
            sumLow = 0; n = 0
            // Automatic gain per hand, but never more than ~10 dB above the louder hand,
            // so leakage or near-silence is not blown up to full strength.
            peakLow = max(abs(l), peakLow * decay); peakEnv = max(env, peakEnv * decay)
            let floor = max(0.3 * max(peakLow, peakEnv), 0.003)
            let left = l / max(peakLow, floor)
            let level = env / max(peakEnv, floor)
            phase += 2 * Float.pi * 200 / 3000; if phase > 2 * Float.pi { phase -= 2 * Float.pi }
            let right = sinf(phase) * level * level         // squared: quiet parts gentle, peaks strong
            for v in [left, right] { out.append(Int8(max(-127, min(127, v * gain * 127)))) }
        }
    }
}

/// Streams the waveform to a Bluetooth DualSense. `feed` runs on the audio queue.
final class WaveformSink {
    private let mgr: IOHIDManager   // must outlive dev: releasing the manager closes its devices
    private let dev: IOHIDDevice
    private var failed = false
    private let lock = NSLock()
    private var ring = [Int8]()
    private var decimator: Decimator

    init?(gain: Float) {
        mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatchingMultiple(mgr, [0x0CE6, 0x0DF2].map { [kIOHIDVendorIDKey: 0x054C, kIOHIDProductIDKey: $0] } as CFArray)
        IOHIDManagerOpen(mgr, 0)
        guard let d = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>)?.first(where: {
            IOHIDDeviceGetProperty($0, kIOHIDTransportKey as CFString) as? String == "Bluetooth"
        }), IOHIDDeviceOpen(d, 0) == kIOReturnSuccess else { return nil }
        dev = d
        decimator = Decimator(gain: gain)
    }

    func feed(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Float) {
        lock.lock(); defer { lock.unlock() }
        decimator.process(samples, count: count, sampleRate: sampleRate, into: &ring)
        // If the link falls behind, drop the oldest sound rather than lag: keep at most 150 ms.
        if ring.count > 900 { ring.removeFirst(ring.count - 900) }
    }

    private func send(_ r: [UInt8]) {
        let res = r.withUnsafeBufferPointer { IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(r[0]), $0.baseAddress!, r.count) }
        if res != kIOReturnSuccess, !failed { failed = true; print(String(format: "Could not send to the controller (0x%08x). Is it still connected?", res)) }
    }

    func start() {
        Thread.detachNewThread { [self] in
            send(WaveReport.setup())
            let need = WaveReport.frames * 2
            var seq: UInt8 = 1, counter: UInt8 = 0
            // Paced by the sound itself (exactly 3000 frames/s arrive): send as soon as a report's
            // worth is ready. A fixed timer drifted against the 20 ms capture buffers and skipped
            // whole reports, which was felt as stutter.
            while true {
                lock.lock()
                let chunk = ring.count >= need ? Array(ring.prefix(need)) : nil
                if chunk != nil { ring.removeFirst(need) }
                lock.unlock()
                guard let chunk else { Thread.sleep(forTimeInterval: 0.002); continue }
                send(WaveReport.audio(seq: seq, counter: counter, samples: chunk))
                seq &+= 1; counter &+= 2
                // macOS re-sends its own state (with rumble emulation selected) whenever the frontmost
                // app changes, which mutes the waveform; re-assert ours about once a second.
                if seq % 48 == 0 { send(WaveReport.setup()) }
            }
        }
    }
}

/// Game Mode halves the controller's Bluetooth interval to 7.5 ms, which the waveform needs.
/// shortcut: uses Xcode's gamepolicyctl; without Xcode the user must have a game in full screen.
@discardableResult func setGameMode(_ on: Bool) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    p.arguments = ["gamepolicyctl", "game-mode", "set", on ? "on" : "auto"]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}
