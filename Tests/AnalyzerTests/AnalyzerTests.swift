import XCTest
@testable import dualsense_music

final class AnalyzerTests: XCTestCase {
    let sr: Float = 48000

    /// Feeds `seconds` of signal in 20 ms buffers (like ScreenCaptureKit); returns levels per buffer.
    func run(_ a: Analyzer, seconds: Float, from t0: Float = 0, _ f: (Float) -> Float) -> [(Float, Float)] {
        var out: [(Float, Float)] = []
        let n = Int(sr * 0.02)
        for k in 0..<Int(seconds / 0.02) {
            var buf = [Float](repeating: 0, count: n)
            for i in 0..<n { buf[i] = f(t0 + Float(k * n + i) / sr) } // index-based: no float drift
            buf.withUnsafeBufferPointer { a.process($0.baseAddress!, count: n, sampleRate: sr) }
            out.append(a.levels)
        }
        return out
    }

    func testSilenceStaysStill() {
        let lv = run(Analyzer(), seconds: 1) { _ in 0 }
        XCTAssertEqual(lv.last!.0, 0); XCTAssertEqual(lv.last!.1, 0)
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
        let words = cycles.filter { (3..<9).contains($0.offset % 15) }.map { $0.element.1 }
        let gaps = cycles.filter { (12..<15).contains($0.offset % 15) }.map { $0.element.1 }
        XCTAssertGreaterThan(words.min()!, 0.3, "words must be felt in the right grip")
        XCTAssertEqual(gaps.max()!, 0, accuracy: 0.02, "pauses must go still in the right grip")
        XCTAssertGreaterThan(lv.last!.0, 0.2, "steady bass keeps the left grip going")
    }

    func testBassGoesLeftVoiceGoesRight() {
        let bass = run(Analyzer(), seconds: 1) { t in 0.5 * sinf(2 * .pi * 50 * t) }.last!
        XCTAssertGreaterThan(bass.0, 0.3); XCTAssertLessThan(bass.1, 0.05)
        let voice = run(Analyzer(), seconds: 1) { t in 0.5 * sinf(2 * .pi * 800 * t) }.last!
        XCTAssertGreaterThan(voice.1, 0.3); XCTAssertLessThan(voice.0, 0.05)
    }
}
