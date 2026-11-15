import Foundation

/// What one grip should do right now. All values 0...1.
struct Grip: Equatable {
    var level: Float = 0      // continuous vibration strength
    var sharpness: Float = 0  // dull (deep sound) ... crisp (bright sound)
    var tap: Float = 0        // strength of a click for a new hit/note/syllable; 0 = none
    var crisp = false         // the tap is a hi-hat or cymbal: play it as sharp as possible
}

/// Converts raw samples into what the bass (left) and voice/melody (right) grips should do.
/// Thread-confined to the audio queue, except `read()`, which is called under a lock.
final class Analyzer {
    private let lock = NSLock()
    private var queue: [(Grip, Grip)] = []   // one entry per ~2 ms slice, oldest first
    private var last = (Grip(), Grip())

    /// The next `slices` slices (default: all that are waiting) merged into one state per grip:
    /// the strongest level and tap win, so a hit shorter than one update is still felt.
    /// With nothing waiting, the previous state without its tap.
    func read(slices: Int = .max) -> (Grip, Grip) {
        lock.lock(); defer { lock.unlock() }
        let n = min(slices, queue.count)
        guard n > 0 else { last.0.tap = 0; last.1.tap = 0; return last }
        func merge(_ a: Grip, _ b: Grip) -> Grip {
            Grip(level: max(a.level, b.level), sharpness: b.sharpness, tap: max(a.tap, b.tap), crisp: b.tap > a.tap ? b.crisp : a.crisp)
        }
        var r = queue[0]
        for s in queue[1..<n] { r = (merge(r.0, s.0), merge(r.1, s.1)) }
        queue.removeFirst(n)
        last = r
        return r
    }

    /// One frequency band with its own envelope, recent average and running peak.
    struct Band {
        let lowCut: Float?, highCut: Float?   // Hz; two one-pole stages each, ~12 dB/octave
        let release: Float                    // seconds; short release = gaps you can feel
        let contrastFloor: Float              // below this fraction of the recent average → 0
        let splitHz: Float                    // energy above vs below this sets sharpness
        var sustain: Float = 1                // level a held sound settles to after its strike, as a fraction
        var fade: Float = 0.12                // seconds for a strike to fade toward `sustain`
        var hp1: Float = 0, hp2: Float = 0, hpIn1: Float = 0, hpIn2: Float = 0
        var lp1: Float = 0, lp2: Float = 0, split: Float = 0
        var env: Float = 0, slow: Float = 0, peak: Float = 1e-4
        var brightness: Float = 0, sinceTap: Float = 1, sinceStrike: Float = 10
        var valley: [Float] = [], strike: (age: Float, rise: Float, level: Float)?

        mutating func filter(_ x: Float, sampleRate: Float) -> Float {
            var y = x
            if let f = lowCut { // high-pass
                let a = 1 / (1 + 2 * Float.pi * f / sampleRate)
                let o1 = a * (hp1 + y - hpIn1); hpIn1 = y; hp1 = o1
                let o2 = a * (hp2 + o1 - hpIn2); hpIn2 = o1; hp2 = o2
                y = o2
            }
            if let f = highCut { // low-pass
                let a = 1 - expf(-2 * Float.pi * f / sampleRate)
                lp1 += a * (y - lp1); lp2 += a * (lp1 - lp2)
                y = lp2
            }
            return y
        }

        /// Splits a filtered sample around `splitHz`; returns (below, above).
        mutating func halves(_ y: Float, sampleRate: Float) -> (Float, Float) {
            split += (1 - expf(-2 * Float.pi * splitHz / sampleRate)) * (y - split)
            return (split, y - split)
        }

        /// Feed one short slice's energies; returns what the grip should do.
        /// `reference` is the whole signal's running peak: a band is never scaled up past it,
        /// so leakage from another band can't turn into full vibration.
        mutating func update(rms: Float, below: Float, above: Float, seconds dt: Float, reference: Float, total: Float = 0) -> Grip {
            func follow(_ v: inout Float, _ target: Float, _ t: Float) { v += (target - v) * (1 - expf(-dt / t)) }
            let rising = rms > env
            follow(&env, rms, rising ? 0.003 : release)
            follow(&slow, env, 0.4)
            // 20 s memory: a quiet build-up stays quiet, so the drop after it hits hard.
            peak = max(env, peak * expf(-dt / 20), 1e-4)
            // Contrast: sound quieter than its recent average (a pause between words, the space
            // between notes) drops to zero; steady sound stays; new sound stands out.
            let ratio = env / max(slow, 1e-7)
            let contrast = min(max((ratio - contrastFloor) / (1.1 - contrastFloor), 0), 1)
            // What is 28 dB or more under the whole sound right now is another band leaking through
            // the filters, not this band's own content: keep it out of this hand.
            let own = min(max((env / max(total, 1e-7) - 0.04) / 0.04, 0), 1)
            let level = Analyzer.shape(env, peak: max(peak, reference * 0.3)) * contrast * own

            if below + above > 1e-12 { follow(&brightness, above / (below + above), 0.03) }
            let sharpness = min(max((brightness - 0.15) / 0.6, 0), 1)

            // A tap: sound rises well above its quietest point of the last 50 ms (new hit, key press,
            // syllable), at most ~11 per second. Comparing with the quietest point, not an average,
            // catches a new note struck while earlier ones still ring. Tuned on real songs: this
            // finds ~87% of piano key presses where an average-based test found 38%.
            valley.append(env); if valley.count > max(1, Int(0.05 / dt)) { valley.removeFirst() }
            let rise = env / max(valley.min()!, 1e-7)
            sinceTap += dt
            if strike == nil, rising, rise > 1.35, env > 1e-4, sinceTap > 0.09 { strike = (0, 0, 0) }
            var tap: Float = 0
            if var s = strike {
                // Wait 12 ms for the note to reach its height, so the tap can be as strong as the hit.
                s.age += dt; s.rise = max(s.rise, rise)
                s.level = max(s.level, Analyzer.shape(env, peak: max(peak, reference * 0.3)))
                strike = s
                if s.age >= 0.012 {
                    // A note that doubles the sound taps at full strength; one that barely lifts it, softly.
                    if s.level > 0.08 { tap = s.level * min(1, 0.4 + 0.6 * (s.rise - 1)); sinceTap = 0 }
                    strike = nil
                }
            }
            // Each strike is a pulse that fades toward `sustain`, so four notes in a second are
            // felt as four pulses, not one long rumble.
            sinceStrike = strike != nil || tap > 0 ? 0 : sinceStrike + dt   // from the first moment of the strike
            let pulse = sustain + (1 - sustain) * expf(-sinceStrike / fade)
            return Grip(level: level * pulse, sharpness: sharpness, tap: tap)
        }
    }

    private var bass = Band(lowCut: nil, highCut: 120, release: 0.045, contrastFloor: 0.15, splitHz: 60, sustain: 0.6)
    private var voice = Band(lowCut: 300, highCut: 3000, release: 0.02, contrastFloor: 0.55, splitHz: 1000, sustain: 0.4, fade: 0.07)
    // Hi-hats and cymbals: never a continuous buzz (it would blur the voice), only light crisp taps.
    private var hats = Band(lowCut: 5000, highCut: nil, release: 0.02, contrastFloor: 0.55, splitHz: 8000)
    private var totalEnv: Float = 0, totalPeak: Float = 1e-4
    private var pendingHat: (age: Float, strength: Float)?

    func process(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Float) {
        // Work in ~2 ms slices: macOS delivers 20 ms buffers, which would smear short gaps.
        let slice = max(1, Int(sampleRate / 500))
        var slices: [(Grip, Grip)] = [], start = 0
        while start < count {
            let n = min(slice, count - start)
            var sumLow: Float = 0, sumHigh: Float = 0, sumAll: Float = 0, sumHats: Float = 0
            var lowParts: (Float, Float) = (0, 0), highParts: (Float, Float) = (0, 0)
            for i in start..<start + n {
                let x = samples[i]
                let b = bass.filter(x, sampleRate: sampleRate)
                let v = voice.filter(x, sampleRate: sampleRate)
                let bh = bass.halves(b, sampleRate: sampleRate), vh = voice.halves(v, sampleRate: sampleRate)
                lowParts.0 += bh.0 * bh.0; lowParts.1 += bh.1 * bh.1
                highParts.0 += vh.0 * vh.0; highParts.1 += vh.1 * vh.1
                let h = hats.filter(x, sampleRate: sampleRate)
                sumLow += b * b; sumHigh += v * v; sumAll += x * x; sumHats += h * h
            }
            let dt = Float(n) / sampleRate
            let rmsAll = sqrtf(sumAll / Float(n))
            totalEnv += (rmsAll - totalEnv) * (1 - expf(-dt / (rmsAll > totalEnv ? 0.003 : 0.045)))
            totalPeak = max(totalEnv, totalPeak * expf(-dt / 20), 1e-4)
            let low = bass.update(rms: sqrtf(sumLow / Float(n)), below: lowParts.0, above: lowParts.1, seconds: dt, reference: totalPeak, total: totalEnv)
            var high = voice.update(rms: sqrtf(sumHigh / Float(n)), below: highParts.0, above: highParts.1, seconds: dt, reference: totalPeak, total: totalEnv)
            let hat = hats.update(rms: sqrtf(sumHats / Float(n)), below: 0, above: 0, seconds: dt, reference: totalPeak).tap
            // A note or syllable has treble of its own: one event, one tap. So a hat tap waits
            // 20 ms and is dropped if the voice hand strikes in that time or just did.
            if hat > 0 { pendingHat = (0, hat * 0.5) }
            if voice.strike != nil || high.tap > 0 || voice.sinceTap < 0.09 { pendingHat = nil }
            if let h = pendingHat {
                if h.age >= 0.02 { high.tap = h.strength; high.crisp = true; pendingHat = nil } else { pendingHat = (h.age + dt, h.strength) }
            }
            slices.append((low, high))
            start += n
        }
        lock.lock()
        queue += slices
        // If the reader falls behind, skip ahead rather than lag: keep at most ~80 ms.
        if queue.count > 40 { queue.removeFirst(queue.count - 40) }
        lock.unlock()
    }

    /// Map an envelope to 0...1 on a 36 dB window below the running peak, with a silence gate.
    /// (24 dB left the quiet background of a dense song, 20 dB under its kicks, at 3%: not felt.)
    static func shape(_ env: Float, peak: Float) -> Float {
        let db = 20 * log10f(max(env, 1e-7))
        if db < -60 { return 0 } // true silence: stay still
        let x = min(max(1 + (db - 20 * log10f(peak)) / 36, 0), 1)
        return powf(x, 2.2) // perceptual curve: quiet parts gentle, peaks strong
    }

    /// Final strength sent to the controller. `gain` sets the everyday strength; the loudest
    /// moments (level near 1) still reach full power, so a beat hits harder than the rest.
    static func strength(_ level: Float, gain: Float) -> Float {
        min(1, level * gain + max(0, 1 - gain) * powf(level, 4))
    }
}
