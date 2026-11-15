import Foundation

/// What one grip should do right now. All values 0...1.
struct Grip: Equatable {
    var level: Float = 0      // continuous vibration strength
    var sharpness: Float = 0  // dull (deep sound) ... crisp (bright sound)
    var tap: Float = 0        // strength of a click for a new hit/note/syllable; 0 = none
}

/// Converts raw samples into what the bass (left) and voice/melody (right) grips should do.
/// Thread-confined to the audio queue, except `read()`, which is called under a lock.
final class Analyzer {
    private let lock = NSLock()
    private var out = (Grip(), Grip())

    /// Latest state of both grips. Taps since the last read are returned once, then cleared.
    func read() -> (Grip, Grip) {
        lock.lock(); defer { lock.unlock() }
        let r = out; out.0.tap = 0; out.1.tap = 0
        return r
    }

    /// One frequency band with its own envelope, recent average and running peak.
    struct Band {
        let lowCut: Float?, highCut: Float?   // Hz; two one-pole stages each, ~12 dB/octave
        let release: Float                    // seconds; short release = gaps you can feel
        let contrastFloor: Float              // below this fraction of the recent average → 0
        let splitHz: Float                    // energy above vs below this sets sharpness
        var hp1: Float = 0, hp2: Float = 0, hpIn1: Float = 0, hpIn2: Float = 0
        var lp1: Float = 0, lp2: Float = 0, split: Float = 0
        var env: Float = 0, slow: Float = 0, peak: Float = 1e-4
        var brightness: Float = 0, sinceTap: Float = 1, recent: Float = 0

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
        mutating func update(rms: Float, below: Float, above: Float, seconds dt: Float, reference: Float) -> Grip {
            func follow(_ v: inout Float, _ target: Float, _ t: Float) { v += (target - v) * (1 - expf(-dt / t)) }
            let rising = rms > env
            follow(&env, rms, rising ? 0.003 : release)
            follow(&slow, env, 0.4)
            peak = max(env, peak * expf(-dt / 5), 1e-4)
            // Contrast: sound quieter than its recent average (a pause between words, the space
            // between notes) drops to zero; steady sound stays; new sound stands out.
            let ratio = env / max(slow, 1e-7)
            let contrast = min(max((ratio - contrastFloor) / (1.1 - contrastFloor), 0), 1)
            let level = Analyzer.shape(env, peak: max(peak, reference * 0.3)) * contrast

            if below + above > 1e-12 { follow(&brightness, above / (below + above), 0.03) }
            let sharpness = min(max((brightness - 0.15) / 0.6, 0), 1)

            // A tap: sound jumps well above where it was ~40 ms ago (new hit, note, syllable),
            // at most ~11 per second so they stay distinct. A held note catches up and stops tapping.
            follow(&recent, env, 0.04)
            sinceTap += dt
            var tap: Float = 0
            if rising, env > 1.5 * recent, level > 0.12, sinceTap > 0.09 { tap = level; sinceTap = 0 }
            return Grip(level: level, sharpness: sharpness, tap: tap)
        }
    }

    private var bass = Band(lowCut: nil, highCut: 120, release: 0.045, contrastFloor: 0.4, splitHz: 60)
    private var voice = Band(lowCut: 300, highCut: 3000, release: 0.02, contrastFloor: 0.55, splitHz: 1000)
    private var totalEnv: Float = 0, totalPeak: Float = 1e-4

    func process(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Float) {
        // Work in ~2 ms slices: macOS delivers 20 ms buffers, which would smear short gaps.
        let slice = max(1, Int(sampleRate / 500))
        var low = Grip(), high = Grip(), tapLow: Float = 0, tapHigh: Float = 0, start = 0
        while start < count {
            let n = min(slice, count - start)
            var sumLow: Float = 0, sumHigh: Float = 0, sumAll: Float = 0
            var lowParts: (Float, Float) = (0, 0), highParts: (Float, Float) = (0, 0)
            for i in start..<start + n {
                let x = samples[i]
                let b = bass.filter(x, sampleRate: sampleRate)
                let v = voice.filter(x, sampleRate: sampleRate)
                let bh = bass.halves(b, sampleRate: sampleRate), vh = voice.halves(v, sampleRate: sampleRate)
                lowParts.0 += bh.0 * bh.0; lowParts.1 += bh.1 * bh.1
                highParts.0 += vh.0 * vh.0; highParts.1 += vh.1 * vh.1
                sumLow += b * b; sumHigh += v * v; sumAll += x * x
            }
            let dt = Float(n) / sampleRate
            let rmsAll = sqrtf(sumAll / Float(n))
            totalEnv += (rmsAll - totalEnv) * (1 - expf(-dt / (rmsAll > totalEnv ? 0.003 : 0.045)))
            totalPeak = max(totalEnv, totalPeak * expf(-dt / 5), 1e-4)
            low = bass.update(rms: sqrtf(sumLow / Float(n)), below: lowParts.0, above: lowParts.1, seconds: dt, reference: totalPeak)
            high = voice.update(rms: sqrtf(sumHigh / Float(n)), below: highParts.0, above: highParts.1, seconds: dt, reference: totalPeak)
            tapLow = max(tapLow, low.tap); tapHigh = max(tapHigh, high.tap)
            start += n
        }
        lock.lock()
        // Keep any tap not yet read; a 20 ms buffer can hold one.
        low.tap = max(tapLow, out.0.tap); high.tap = max(tapHigh, out.1.tap)
        out = (low, high)
        lock.unlock()
    }

    /// Map an envelope to 0...1 on a 24 dB window below the running peak, with a silence gate.
    static func shape(_ env: Float, peak: Float) -> Float {
        let db = 20 * log10f(max(env, 1e-7))
        if db < -60 { return 0 } // true silence: stay still
        let x = min(max(1 + (db - 20 * log10f(peak)) / 24, 0), 1)
        return x * x // perceptual curve: quiet parts gentle, peaks strong
    }
}
