import XCTest
@testable import dualsense_music

final class AnalyzerTests: XCTestCase {
    let sr: Float = 48000

    /// Feeds `seconds` of signal in 20 ms buffers (like ScreenCaptureKit); returns levels per buffer.
    func run(_ a: Analyzer, seconds: Float, from t0: Float = 0, _ f: (Float) -> Float) -> [(Grip, Grip)] {
        var out: [(Grip, Grip)] = []
        let n = Int(sr * 0.02)
        for k in 0..<Int(seconds / 0.02) {
            var buf = [Float](repeating: 0, count: n)
            for i in 0..<n { buf[i] = f(t0 + Float(k * n + i) / sr) } // index-based: no float drift
            buf.withUnsafeBufferPointer { a.process($0.baseAddress!, count: n, sampleRate: sr) }
            out.append(a.read())
        }
        return out
    }

    func testSilenceStaysStill() {
        let lv = run(Analyzer(), seconds: 1) { _ in 0 }
        XCTAssertEqual(lv.last!.0, Grip(sharpness: lv.last!.0.sharpness)); XCTAssertEqual(lv.last!.1, Grip(sharpness: lv.last!.1.sharpness))
        XCTAssertFalse(lv.contains { $0.0.tap > 0 || $0.1.tap > 0 }, "silence must never tap")
    }

    func testPausesBetweenWordsAreFelt() {
        // "Words": 1 kHz bursts 200 ms on, 100 ms off, over a steady 60 Hz bass line.
        let a = Analyzer()
        let lv = run(a, seconds: 3) { t in
            let on = t.truncatingRemainder(dividingBy: 0.3) < 0.2
            return (on ? 0.3 * sinf(2 * .pi * 1000 * t) : 0) + 0.3 * sinf(2 * .pi * 60 * t)
        }
        // Buffers are 20 ms; cycle is 15 buffers: 10 on, 5 off. Skip the first second (warm-up).
        let cycles = lv.enumerated().filter { $0.offset >= 50 }
        let words = cycles.filter { (3..<9).contains($0.offset % 15) }.map { $0.element.1.level }
        let gaps = cycles.filter { (12..<15).contains($0.offset % 15) }.map { $0.element.1.level }
        XCTAssertGreaterThan(words.min()!, 0.3, "words must be felt in the right grip")
        XCTAssertEqual(gaps.max()!, 0, accuracy: 0.02, "pauses must go still in the right grip")
        XCTAssertGreaterThan(lv.last!.0.level, 0.2, "steady bass keeps the left grip going")
    }

    func testBassGoesLeftVoiceGoesRight() {
        let bass = run(Analyzer(), seconds: 1) { t in 0.5 * sinf(2 * .pi * 50 * t) }.last!
        XCTAssertGreaterThan(bass.0.level, 0.3); XCTAssertLessThan(bass.1.level, 0.05)
        let voice = run(Analyzer(), seconds: 1) { t in 0.5 * sinf(2 * .pi * 800 * t) }.last!
        XCTAssertGreaterThan(voice.1.level, 0.3); XCTAssertLessThan(voice.0.level, 0.05)
    }

    func testBrightSoundFeelsCrisperThanDeep() {
        let tone = { (hz: Float) in self.run(Analyzer(), seconds: 1) { t in 0.5 * sinf(2 * .pi * hz * t) }.last! }
        XCTAssertGreaterThan(tone(2500).1.sharpness, tone(400).1.sharpness + 0.5, "high voice crisper than low voice")
        XCTAssertGreaterThan(tone(100).0.sharpness, tone(40).0.sharpness + 0.3, "kick crisper than sub-bass")
    }

    func testEveryNewWordTapsButSteadySoundDoesNot() {
        // Same "words" as above: a burst every 300 ms → one tap per word, none in between.
        let lv = run(Analyzer(), seconds: 3) { t in
            t.truncatingRemainder(dividingBy: 0.3) < 0.2 ? 0.3 * sinf(2 * .pi * 1000 * t) : 0
        }
        let taps = lv.enumerated().filter { $0.element.1.tap > 0 }.map { $0.offset }
        XCTAssertEqual(taps.count, 10, "one tap per word")
        XCTAssertTrue(taps.allSatisfy { $0 % 15 == 0 }, "taps land on word starts: \(taps)")
        let steady = run(Analyzer(), seconds: 2) { t in 0.3 * sinf(2 * .pi * 1000 * t) }
        XCTAssertEqual(steady.dropFirst(2).filter { $0.1.tap > 0 }.count, 0, "a held note taps only once")
    }

    func testShortHitInsideABufferIsNotLost() {
        // A 6 ms click at the start of a 20 ms buffer has faded by the buffer's end;
        // it must still come out as a strong level, in order, when read in 8 ms steps.
        let a = Analyzer()
        _ = run(a, seconds: 1) { t in 0.02 * sinf(2 * .pi * 800 * t) }   // quiet bed
        let n = Int(sr * 0.02)
        let buf = (0..<n).map { i -> Float in (i < 288 ? 0.5 : 0.02) * sinf(2 * .pi * 800 * Float(i) / sr) }
        buf.withUnsafeBufferPointer { a.process($0.baseAddress!, count: n, sampleRate: sr) }
        XCTAssertGreaterThan(a.read(slices: 4).1.level, 0.8, "the click is felt at full strength")
        let after = run(a, seconds: 0.08, from: 1.02) { t in 0.02 * sinf(2 * .pi * 800 * t) }.last!.1.level
        XCTAssertLessThan(after, 0.25, "and is over again 80 ms later")
    }

    func testDropAfterQuietBuildUpStandsOut() {
        // 10 s loud, 8 s at one tenth the level (build-up), then loud again (the drop).
        let a = Analyzer()
        let bass = { (amp: Float) in { (t: Float) in amp * sinf(2 * .pi * 50 * t) } }
        _ = run(a, seconds: 10, bass(0.5))
        let quiet = run(a, seconds: 8, from: 10, bass(0.05)).last!.0.level
        let drop = run(a, seconds: 1, from: 18, bass(0.5)).map { $0.0.level }.max()!
        XCTAssertGreaterThan(quiet, 0.05, "the build-up is still felt")
        XCTAssertLessThan(quiet, 0.3, "but must not be turned up to full")
        XCTAssertGreaterThan(drop, 0.9); XCTAssertGreaterThan(drop, quiet * 3)
    }

    func testNewNoteOverRingingNoteTaps() {
        // Piano: a note is held, then a second key is pressed while the first still rings.
        // The total only grows by about half, which an average-based test missed.
        let lv = run(Analyzer(), seconds: 2) { t in
            0.3 * sinf(2 * .pi * 600 * t) + (t >= 1 ? 0.2 * sinf(2 * .pi * 900 * t) : 0)
        }
        let taps = lv.enumerated().filter { $0.element.1.tap > 0 }.map { $0.offset }
        XCTAssertEqual(taps.count, 2, "one tap per key press: \(taps)")
        XCTAssertTrue((50...52).contains(taps.last!), "second tap lands on the second key press: \(taps)")
        // The softer second press taps more softly than the first, which came out of silence.
        XCTAssertLessThan(lv[taps[1]].1.tap, lv[taps[0]].1.tap)
    }

    func testFourNotesInASecondAreFourPulses() {
        // Four overlapping notes, 250 ms apart, each ringing on under the next (like a piano with pedal).
        let hz: [Float] = [440, 523, 659, 784]
        let lv = run(Analyzer(), seconds: 2) { t in
            guard t >= 1 else { return 0 }
            return (0..<4).reduce(Float(0)) { s, k in
                let since = t - 1 - 0.25 * Float(k)
                return since < 0 ? s : s + 0.2 * expf(-since / 0.6) * sinf(2 * .pi * hz[k] * t)
            }
        }.dropFirst(50).map { $0.1.level }
        // Around each note start the level must peak, and dip clearly before the next one.
        for k in 1..<4 {
            let i = Int(12.5 * Float(k))   // 20 ms buffers
            let peak = lv[i...(i + 4)].max()!, before = lv[(i - 4)...(i - 1)].min()!
            XCTAssertGreaterThan(peak, before * 1.5, "note \(k + 1) must stand out from the ringing before it")
        }
    }

    func testHiHatOverMusicTapsCrisply() {
        // A held 600 Hz note with 8 kHz ticks, 10 ms long, twice a second, on top.
        let lv = run(Analyzer(), seconds: 4) { t in
            0.2 * sinf(2 * .pi * 600 * t) + (t.truncatingRemainder(dividingBy: 0.5) < 0.01 ? 0.3 * sinf(2 * .pi * 8000 * t) : 0)
        }.dropFirst(50)   // skip the note's own start
        let taps = lv.filter { $0.1.tap > 0 }
        XCTAssertEqual(taps.count, 6, "one light tap per tick")
        XCTAssertTrue(taps.allSatisfy { $0.1.crisp && $0.1.tap < 0.6 }, "crisp and lighter than a note")
        XCTAssertEqual(lv.filter { $0.0.tap > 0 }.count, 0, "nothing in the bass hand")
    }

    func testLoudestMomentsReachFullPower() {
        XCTAssertEqual(Analyzer.strength(1, gain: 0.7), 1, accuracy: 0.001)       // a beat hits at full power
        XCTAssertEqual(Analyzer.strength(0.5, gain: 0.7), 0.37, accuracy: 0.01)   // everyday level: about gain x level
        XCTAssertEqual(Analyzer.strength(0, gain: 0.7), 0)
    }
}
