// What `EqAnalyserTest.kt` is for the phone: the Swift analyser fed known signals, asserting the
// things a port gets wrong silently.
//
// **Why a harness rather than a unit test.** There is no test target here — one core, three `@main`
// entry points, no Xcode project and no SwiftPM manifest (see `README.md`). Adding a test runner to
// buy four assertions is more machinery than the assertions are worth; a fourth `@main` costs one
// line in `build.sh` and matches how `Preview.swift` already measures the real views.
//
// **The failures it exists to catch are all silent ones.** A mark driven by the wrong end of the
// array looks plausible and is wrong — that shipped once on the phone (`reactive-eq.md` §6b). A
// band count that no longer matches the slat count draws an equalizer missing its top bars. A Q
// that stops tiling leaves holes in the spectrum that read as bands that never move. None of these
// crash, and none of them are visible without knowing what to look for.
//
//     ./build.sh check && ./eq-check

import Foundation

@main
struct EqAnalyserCheck {

    static var failures: [String] = []

    static func expect(_ condition: Bool, _ what: String) {
        if condition { print("  ok   \(what)") } else { print("  FAIL \(what)"); failures.append(what) }
    }

    /// Feed `seconds` of a signal, in the interleaved-planar shape `AVAudioPCMBuffer` hands over.
    static func feed(_ analyser: EqAnalyser, rate: Float, seconds: Float,
                     _ sample: (Int) -> Float) {
        let frames = Int(rate * seconds)
        var channel = [Float](repeating: 0, count: frames)
        for i in 0..<frames { channel[i] = sample(i) }
        channel.withUnsafeMutableBufferPointer { buf in
            var planes: [UnsafeMutablePointer<Float>] = [buf.baseAddress!]
            planes.withUnsafeMutableBufferPointer { p in
                // In chunks, so the sub-block splitting and its remainder are exercised rather
                // than being handed one tidy buffer — the short-remainder bug was real (§6i).
                var off = 0
                let chunk = 2048
                while off < frames {
                    let n = min(chunk, frames - off)
                    var slice: [UnsafeMutablePointer<Float>] = [buf.baseAddress! + off]
                    slice.withUnsafeMutableBufferPointer { sp in
                        analyser.onAudio(sp.baseAddress!, channels: 1, frames: n, rate: rate)
                    }
                    off += n
                }
                _ = p
            }
        }
    }

    /// A tone at `hz` (-39 dBFS peak) arriving for 200 ms over 3 s of a quiet bed, the five band
    /// centres at -45 dBFS peak each, so every band has a mean to rise from. Same as the phone's
    /// `EqAnalyserTest.onset`.
    static func onset(_ hz: Float, rate: Float) -> EqAnalyser {
        let a = EqAnalyser()
        let bed: Float = powf(10, -45 / 20)
        let tone: Float = powf(10, -39 / 20)
        let from = Int(rate * 3)
        feed(a, rate: rate, seconds: 3.2) { i in
            let t = Float(i) / rate
            var v: Float = 0
            for c: Float in [60, 226, 849, 3191, 12_000] { v += bed * sinf(2 * .pi * c * t) }
            if i >= from { v += tone * sinf(2 * .pi * hz * t) }
            return v
        }
        return a
    }

    /// Loudest slat index, and the level there.
    static func peak(_ levels: [CGFloat]) -> (Int, CGFloat) {
        var best = 0
        for i in levels.indices where levels[i] > levels[best] { best = i }
        return (best, levels[best])
    }

    static func main() {
        let rate: Float = 48_000
        print("EqAnalyser — \(EqAnalyser.bands) bands, Q \(String(format: "%.3f", EqAnalyser.bandQ)), "
            + "\(String(format: "%.2f", EqAnalyser.spacingOctaves)) oct apart")

        // 1. The count is the whole contract with the mark. `BlindsEqMark` draws `eqCenters`, and a
        //    mismatch is an equalizer with bars nothing drives. Compared against the mark's own
        //    count rather than a literal, so this assertion survives the count changing — it has
        //    changed twice already.
        expect(EqAnalyser.bands == blindsEqSlats,
               "band count \(EqAnalyser.bands) matches the mark's \(blindsEqSlats) slats")
        expect(EqAnalyser.bands >= 2, "at least two bands, or the spacing is a division by zero")

        // 2. Q tiles: the passband width must equal the spacing, or the spectrum has holes that
        //    read as dead bands. This is the assertion that stops someone "simplifying" the
        //    derivation into a constant.
        let u = sqrtf(powf(2, 1.0 / 2.0) - 1) / EqAnalyser.bandQ
        let widthOct = 2 * log2f((u + sqrtf(u * u + 4)) / 2)
        expect(abs(widthOct - EqAnalyser.spacingOctaves) < 0.01,
               "passband width \(String(format: "%.2f", widthOct)) oct == spacing "
             + "\(String(format: "%.2f", EqAnalyser.spacingOctaves)) oct")

        // 3. Nothing at all means nothing to show, and the caller falls back to the canned walk.
        let fresh = EqAnalyser()
        expect(fresh.levels() == nil, "no audio yet reads as nil, not as rest")

        // 4. Bass drives the BOTTOM slat. Band order is not slat order, and getting it backwards
        //    is invisible until someone notices the hairlines thumping.
        //    **An onset over a quiet bed, not a steady tone**: the mapping is relative to each band's
        //    own recent level, so a steady tone settles every band it reaches at mid-travel. A
        //    steady tone passed here only while one quiet first block could hold a mean under the
        //    music for seconds (fixed 2026-10-18, check 10). The tone is 6 dB over the bed so a
        //    neighbour's skirt does not saturate too and tie with it.
        let bass = onset(60, rate: rate)
        if let l = bass.newestLevels() {
            let (idx, level) = peak(l)
            expect(idx == EqAnalyser.bands - 1,
                   "a 60 Hz tone peaks on the bottom slat (got index \(idx) of \(l.count))")
            expect(level > 0.5, "and drives it well past rest (\(String(format: "%.2f", level)))")
        } else {
            expect(false, "a 60 Hz tone produces levels at all")
        }

        // 5. Treble drives the TOP slat — the other end of the same mapping, because a reversal
        //    that is wrong in one direction is wrong in both and one test can miss it.
        let treble = onset(12_000, rate: rate)
        if let l = treble.newestLevels() {
            let (idx, _) = peak(l)
            expect(idx == 0, "a 12 kHz tone peaks on the top slat (got index \(idx))")
        } else {
            expect(false, "a 12 kHz tone produces levels at all")
        }

        // 6. Digital silence rests — it does NOT return nil, and it is not masked with a dance.
        //    "No usable tap" and "a quiet passage" are different things; conflating them is the
        //    bug `reactive-eq.md` §6d ends with a rule.
        let quiet = EqAnalyser()
        feed(quiet, rate: rate, seconds: 2) { _ in 0 }
        if let l = quiet.newestLevels() {
            let (_, level) = peak(l)
            expect(level <= CGFloat(EqAnalyser.restingLevel) + 0.001,
                   "digital silence rests rather than dancing (peak \(String(format: "%.3f", level)))")
        } else {
            expect(false, "silence still counts as having seen audio")
        }

        // 7. Material at the gate's own level reads as rest, which is what makes the derived lift
        //    cap `floor - gate` the right number rather than a third guess (§6g). -58 dBFS is the
        //    level `She Left` opens on, where an uncapped gain lifted hiss to near-full bars.
        let hiss = EqAnalyser()
        let amp: Float = powf(10, -58 / 20)
        feed(hiss, rate: rate, seconds: 3) { i in
            amp * sinf(2 * .pi * 800 * Float(i) / rate)
        }
        if let l = hiss.newestLevels() {
            let (_, level) = peak(l)
            expect(level < 0.35,
                   "a -58 dBFS tone stays near rest (peak \(String(format: "%.2f", level)))")
        }

        // 8. The ring paces a burst instead of collapsing it. `installTap` ignores the requested
        //    buffer size and delivers 100 ms at a time (measured: asked 735 frames, got 4410), so
        //    without pacing the mark ran at 10 Hz whatever the display link did. Feeding a burst
        //    instantly must therefore leave most of it *not yet due*.
        let paced = EqAnalyser()
        feed(paced, rate: rate, seconds: 1) { i in 0.4 * sinf(2 * .pi * 220 * Float(i) / rate) }
        expect(paced.newestLevels() != nil, "a burst is computed immediately")
        let due = paced.levels()
        let newest = paced.newestLevels()
        expect(due != nil && newest != nil && due! != newest!,
               "one second fed instantly is not all shown instantly — the ring paces it")

        // 9. The auto-gain reads K-weighted loudness, as the phone does: ~1 kHz at its RMS, bass
        //    under it, treble over it (BS.1770's closed-form response at 48 kHz).
        let rmsDb = 20 * log10f(0.4 / sqrtf(2))
        for (hz, want) in [(997, 0.0), (60, -3.59), (10_000, 3.35)] as [(Float, Float)] {
            let k = EqAnalyser()
            feed(k, rate: 48_000, seconds: 1) { i in 0.4 * sinf(2 * .pi * hz * Float(i) / 48_000) }
            let got = k.lastLoudnessDb - rmsDb
            expect(abs(got - want) < 0.15,
                   "K-weighting at \(Int(hz)) Hz reads \(String(format: "%+.2f", got)) dB (want \(want))")
        }

        // 10. A loud start after one quiet block settles in well under a second (`Two-Way Mirror`:
        //     -29 dB, then -10 within 100 ms). A seeded EMA held every slat full for ~5 s.
        let start = EqAnalyser()
        let quietAmp: Float = powf(10, -29 / 20) * sqrtf(2)
        let quietFrames = Int(rate / 60)
        feed(start, rate: rate, seconds: 1) { i in
            (i < quietFrames ? quietAmp : 0.4) * sinf(2 * .pi * 440 * Float(i) / rate)
        }
        if let l = start.newestLevels() {
            let (_, level) = peak(l)
            expect(level < 0.8, "a loud start after a quiet block is not full a second in (peak \(String(format: "%.2f", level)))")
        }

        print(failures.isEmpty
              ? "\nall checks passed"
              : "\n\(failures.count) FAILED:\n  - " + failures.joined(separator: "\n  - "))
        exit(failures.isEmpty ? 0 : 1)
    }
}
