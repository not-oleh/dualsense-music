import XCTest
@testable import dualsense_music

final class WaveformTests: XCTestCase {
    func testCRCMatchesStandardCheckValue() {
        XCTAssertEqual(WaveReport.crc32(Array("123456789".utf8)), 0xCBF43926)
    }

    func testAudioReportLayout() {
        let samples = (0..<124).map { Int8($0 - 62) }
        let r = WaveReport.audio(seq: 0x13, counter: 7, samples: samples)
        XCTAssertEqual(r.count, 142)                       // 141 was silently dropped by the controller
        XCTAssertEqual(Array(r[0...4]), [0x32, 0x30, 0x91, 7, 0xFE])
        XCTAssertEqual(r[10], 7)
        XCTAssertEqual(Array(r[11...12]), [0xD2, 62])      // double-length packet: 124 bytes
        XCTAssertEqual(r[13], UInt8(bitPattern: -62)); XCTAssertEqual(r[136], 61)
        let crc = WaveReport.crc32([0xA2] + r.dropLast(4))
        XCTAssertEqual(Array(r[138...]), (0..<4).map { UInt8((crc >> (8 * UInt32($0))) & 0xFF) })
    }

    func testDecimatorBassLeftVoiceBuzzRight() {
        func run(_ f: (Int) -> Float) -> (left: [Int], right: [Int]) {
            var d = Decimator(gain: 1), out = [Int8]()
            let buf = (0..<48000).map(f)
            d.process(buf, count: buf.count, sampleRate: 48000, into: &out)
            XCTAssertEqual(out.count, 6000)                // 3000 stereo frames per second
            let tail = Array(out.suffix(3000))             // skip filter settling
            return (stride(from: 0, to: 3000, by: 2).map { abs(Int(tail[$0])) }, stride(from: 1, to: 3000, by: 2).map { abs(Int(tail[$0])) })
        }
        func tone(_ hz: Float, _ amp: Float = 0.5) -> (Int) -> Float { { amp * sinf(2 * .pi * hz * Float($0) / 48000) } }
        let bass = run(tone(50)), mid = run(tone(600))
        XCTAssertGreaterThan(bass.left.max()!, 100); XCTAssertLessThan(bass.right.max()!, 30)
        XCTAssertGreaterThan(mid.right.max()!, 100); XCTAssertLessThan(mid.left.max()!, 50)
        // Quiet music is brought up to full strength; silence stays still.
        XCTAssertGreaterThan(run(tone(600, 0.02)).right.max()!, 100)
        let silent = run { _ in 0 }
        XCTAssertEqual(silent.left.max()!, 0); XCTAssertEqual(silent.right.max()!, 0)
        // A word then a pause: the buzz stops within the pause.
        let gap = run { i in i % 24000 < 12000 ? 0.5 * sinf(2 * .pi * 600 * Float(i) / 48000) : 0 }
        XCTAssertEqual(gap.right.suffix(300).max()!, 0)
    }
}
