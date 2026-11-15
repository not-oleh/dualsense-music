// dualsense-music — feel your Mac's audio through a DualSense controller.
// Audio: ScreenCaptureKit (whole system or one app). Output: Core Haptics via GameController.
import Foundation
import GameController
import CoreHaptics
import ScreenCaptureKit
import CoreMedia

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Options

struct Options {
    var app: String? = nil       // capture only this app (name or bundle id substring)
    var gain: Float = 0.7        // overall strength multiplier
    var listApps = false
    var test = false
}

func parseOptions() -> Options {
    var o = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let a = args.next() {
        switch a {
        case "--app", "-a": o.app = args.next()
        case "--gain", "-g": o.gain = Float(args.next() ?? "") ?? 0.7
        case "--list-apps": o.listApps = true
        case "--test": o.test = true
        case "--help", "-h":
            print("""
            dualsense-music — feel sound through a DualSense controller.

            Usage: dualsense-music [--app NAME] [--gain N] [--list-apps] [--test]
              --app NAME    only feel audio from one app (e.g. "Spotify", "Music", "Safari")
              --gain N      strength multiplier, default 0.7 (try 0.4 to 1.5)
              --list-apps   print apps that can be captured, then exit
              --test        play a short test vibration on both grips, then exit
            Press Control-C to stop.
            """)
            exit(0)
        default:
            print("Unknown option \(a). Use --help."); exit(2)
        }
    }
    return o
}

let opts = parseOptions()

// MARK: - Haptics: one Core Haptics engine per grip

/// Drives one grip. Uses a plain pattern player whose intensity is scaled live; advanced
/// (looping) players drop the gamecontrollerd connection, so we renew the player instead.
final class GripHaptics {
    let engine: CHHapticEngine
    private var player: CHHapticPatternPlayer?
    private var startedAt = Date.distantPast
    private var level: Float = 0
    private static let span: TimeInterval = 30

    private init(engine: CHHapticEngine) { self.engine = engine }

    @MainActor static func make(controller: GCController, locality: GCHapticsLocality) async -> GripHaptics? {
        guard let haptics = controller.haptics,
              haptics.supportedLocalities.contains(locality),
              let engine = haptics.createEngine(withLocality: locality) else { return nil }
        do {
            // Must be the async start: the blocking start() fails for controllers
            // ("Couldn't communicate with a helper application").
            try await engine.start()
        } catch {
            print("Could not start haptics for \(locality.rawValue): \(error.localizedDescription)")
            return nil
        }
        let g = GripHaptics(engine: engine)
        engine.resetHandler = { [weak g] in
            DispatchQueue.main.async { try? g?.engine.start(); g?.player = nil }
        }
        return g
    }

    /// Set vibration strength 0...1. Call from the main queue.
    func set(_ v: Float) {
        level = v
        if player == nil || Date().timeIntervalSince(startedAt) > GripHaptics.span - 2 { renew() }
        try? player?.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: v, relativeTime: 0)], atTime: CHHapticTimeImmediate)
    }

    /// Start a fresh full-intensity continuous event and drop the old one.
    private func renew() {
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
        ], relativeTime: 0, duration: GripHaptics.span)
        guard let pattern = try? CHHapticPattern(events: [event], parameters: []),
              let next = try? engine.makePlayer(with: pattern) else { return }
        try? next.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: level, relativeTime: 0)], atTime: CHHapticTimeImmediate)
        try? next.start(atTime: CHHapticTimeImmediate)
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = next; startedAt = Date()
    }

    func stop() { try? player?.stop(atTime: CHHapticTimeImmediate); player = nil; engine.stop() }
}

// MARK: - Audio capture (ScreenCaptureKit)

final class AudioTap: NSObject, SCStreamOutput, SCStreamDelegate {
    let analyzer: Analyzer
    var stream: SCStream?
    private var mono = [Float]()
    init(analyzer: Analyzer) { self.analyzer = analyzer }

    func start(appName: String?) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw NSError(domain: "dualsense-music", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"]) }
        let filter: SCContentFilter
        if let name = appName?.lowercased() {
            let apps = content.applications.filter {
                $0.applicationName.lowercased().contains(name) || $0.bundleIdentifier.lowercased().contains(name)
            }
            guard !apps.isEmpty else {
                throw NSError(domain: "dualsense-music", code: 2, userInfo: [NSLocalizedDescriptionKey: "No running app matches \"\(appName!)\". Use --list-apps."])
            }
            print("Listening to: " + apps.map(\.applicationName).joined(separator: ", "))
            filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        } else {
            print("Listening to: all system sound")
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        }
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        // We only want sound; keep the (mandatory) video part as cheap as possible.
        cfg.width = 2; cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "audio"))
        try await s.startCapture()
        stream = s
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid,
              let fmt = sb.formatDescription?.audioStreamBasicDescription else { return }
        try? sb.withAudioBufferList { abl, _ in
            let frames = sb.numSamples
            guard frames > 0, abl.count > 0 else { return }
            if mono.count < frames { mono = [Float](repeating: 0, count: frames) }
            // ScreenCaptureKit delivers non-interleaved Float32; average the channels to mono.
            for i in 0..<frames { mono[i] = 0 }
            for buf in abl {
                guard let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = min(frames, Int(buf.mDataByteSize) / 4)
                for i in 0..<n { mono[i] += p[i] }
            }
            let scale = 1 / Float(abl.count)
            mono.withUnsafeMutableBufferPointer { m in
                for i in 0..<frames { m[i] *= scale }
                analyzer.process(m.baseAddress!, count: frames, sampleRate: Float(fmt.mSampleRate))
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Audio capture stopped: \(error.localizedDescription)")
        exit(1)
    }
}

// MARK: - Main

@MainActor func waitForController() async -> GCController {
    if let c = GCController.controllers().first(where: { $0.haptics != nil }) { return c }
    print("Waiting for a DualSense controller… (pair it in System Settings → Bluetooth)")
    await GCController.startWirelessControllerDiscovery()
    for await note in NotificationCenter.default.notifications(named: .GCControllerDidConnect) {
        if let c = note.object as? GCController, c.haptics != nil { return c }
    }
    fatalError("unreachable")
}

@MainActor
func run() async {
    GCController.shouldMonitorBackgroundEvents = true

    if opts.listApps {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            for a in content.applications.sorted(by: { $0.applicationName < $1.applicationName }) where !a.applicationName.isEmpty {
                print("\(a.applicationName)  (\(a.bundleIdentifier))")
            }
            exit(0)
        } catch { print(permissionHint(error)); exit(1) }
    }

    // Give GameController a moment to enumerate already-paired controllers.
    try? await Task.sleep(nanoseconds: 500_000_000)
    let controller = await waitForController()
    print("Controller: \(controller.vendorName ?? "game controller")")

    guard let left = await GripHaptics.make(controller: controller, locality: .leftHandle),
          let right = await GripHaptics.make(controller: controller, locality: .rightHandle) else {
        print("This controller does not expose left/right haptics."); exit(1)
    }

    // Startup pulse: a felt "I'm ready" signal, so no screen is needed to know it works.
    for (l, r) in [(1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] as [(Float, Float)] {
        left.set(l); right.set(r)
        try? await Task.sleep(nanoseconds: 180_000_000)
        left.set(0); right.set(0)
        try? await Task.sleep(nanoseconds: 120_000_000)
    }
    if opts.test { left.stop(); right.stop(); print("Test done."); exit(0) }

    let analyzer = Analyzer()
    let tap = AudioTap(analyzer: analyzer); activeTap = tap
    do { try await tap.start(appName: opts.app) } catch {
        print(permissionHint(error)); left.stop(); right.stop(); exit(1)
    }
    print("Running. Feel the bass in your left hand, melody and beats in your right. Control-C to stop.")

    // ~100 updates per second: fast enough for drum hits, light on Bluetooth.
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: .milliseconds(10))
    var last: (Float, Float) = (-1, -1)
    timer.setEventHandler {
        let (lo, hi) = analyzer.levels
        let l = min(lo * opts.gain, 1), r = min(hi * opts.gain, 1)
        if abs(l - last.0) > 0.01 || (l == 0 && last.0 != 0) { left.set(l) }
        if abs(r - last.1) > 0.01 || (r == 0 && last.1 != 0) { right.set(r) }
        last = (l, r)
    }
    timer.resume()

    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
    for sig in [SIGINT, SIGTERM] {
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { timer.cancel(); left.stop(); right.stop(); print("\nStopped."); exit(0) }
        src.resume()
        signalSources.append(src)
    }
}

func permissionHint(_ error: Error) -> String {
    if (error as NSError).domain == "dualsense-music" { return error.localizedDescription }
    return """
    Could not capture audio: \(error.localizedDescription)
    macOS needs permission to record sound from other apps. Open
    System Settings → Privacy & Security → Screen & System Audio Recording,
    turn on the app you run this from (for example Terminal), then run again.
    """
}

// Kept alive for the whole run; SCStream does not retain its output.
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []
nonisolated(unsafe) var activeTap: AudioTap?
Task { await run() }
dispatchMain()
