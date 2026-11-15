import Foundation

/// Converts raw samples into two 0...1 vibration levels: bass (left grip) and voice/melody
/// (right grip). Thread-confined to the audio queue, except `levels`, read under a lock.
final class Analyzer {
    private let lock = NSLock()
    private var _low: Float = 0, _high: Float = 0
    var levels: (Float, Float) { lock.lock(); defer { lock.unlock() }; return (_low, _high) }

    /// One frequency band with its own envelope, recent average and running peak.
    struct Band {
        let lowCut: Float?, highCut: Float?   // Hz; two one-pole stages each, ~12 dB/octave
        let release: Float                    // seconds; short release = gaps you can feel
        let contrastFloor: Float              // below this fraction of the recent average → 0
        var hp1: Float = 0, hp2: Float = 0, hpIn1: Float = 0, hpIn2: Float = 0
        var lp1: Float = 0, lp2: Float = 0
        var env: Float = 0, slow: Float = 0, peak: Float = 1e-4

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

        /// Feed one short slice's RMS; returns the 0...1 vibration level.
        /// `reference` is the whole signal's running peak: a band is never scaled up past it,
        /// so leakage from another band can't turn into full vibration.
        mutating func update(rms: Float, seconds dt: Float, reference: Float) -> Float {
            func follow(_ v: inout Float, _ target: Float, _ t: Float) { v += (target - v) * (1 - expf(-dt / t)) }
            follow(&env, rms, rms > env ? 0.003 : release)
            follow(&slow, env, 0.4)
            peak = max(env, peak * expf(-dt / 5), 1e-4)
            // Contrast: sound quieter than its recent average (a pause between words, the space
            // between notes) drops to zero; steady sound stays; new sound stands out.
            let ratio = env / max(slow, 1e-7)
            let contrast = min(max((ratio - contrastFloor) / (1.1 - contrastFloor), 0), 1)
            return Analyzer.shape(env, peak: max(peak, reference * 0.3)) * contrast
        }
    }

    private var bass = Band(lowCut: nil, highCut: 120, release: 0.045, contrastFloor: 0.4)
    private var voice = Band(lowCut: 300, highCut: 3000, release: 0.02, contrastFloor: 0.55)
    private var totalEnv: Float = 0, totalPeak: Float = 1e-4

    func process(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Float) {
        // Work in ~2 ms slices: macOS delivers 20 ms buffers, which would smear short gaps.
        let slice = max(1, Int(sampleRate / 500))
        var low: Float = 0, high: Float = 0, start = 0
        while start < count {
            let n = min(slice, count - start)
            var sumLow: Float = 0, sumHigh: Float = 0, sumAll: Float = 0
            for i in start..<start + n {
                let x = samples[i]
                let b = bass.filter(x, sampleRate: sampleRate)
                let v = voice.filter(x, sampleRate: sampleRate)
                sumLow += b * b; sumHigh += v * v; sumAll += x * x
            }
            let dt = Float(n) / sampleRate
            let rmsAll = sqrtf(sumAll / Float(n))
            totalEnv += (rmsAll - totalEnv) * (1 - expf(-dt / (rmsAll > totalEnv ? 0.003 : 0.045)))
            totalPeak = max(totalEnv, totalPeak * expf(-dt / 5), 1e-4)
            low = bass.update(rms: sqrtf(sumLow / Float(n)), seconds: dt, reference: totalPeak)
            high = voice.update(rms: sqrtf(sumHigh / Float(n)), seconds: dt, reference: totalPeak)
            start += n
        }
        lock.lock(); _low = low; _high = high; lock.unlock()
    }

    /// Map an envelope to 0...1 on a 24 dB window below the running peak, with a silence gate.
    static func shape(_ env: Float, peak: Float) -> Float {
        let db = 20 * log10f(max(env, 1e-7))
        if db < -60 { return 0 } // true silence: stay still
        let x = min(max(1 + (db - 20 * log10f(peak)) / 24, 0), 1)
        return x * x // perceptual curve: quiet parts gentle, peaks strong
    }
}
