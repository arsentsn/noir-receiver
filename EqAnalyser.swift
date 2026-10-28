// The band analyser behind the menu-bar mark — the Swift half of `EqAnalyser.kt`.
//
// **Why this exists rather than the phone sending levels over the wire.** The phone's mark and
// this one are looking at different moments of the same song: the phone is muted while casting
// (`player.volume = 0`) and its own output latency is irrelevant, while what matters here is what
// *this* Mac is emitting, roughly 190 ms of receiver buffer plus the network behind it. A level
// computed from the stream this receiver is about to play is in sync with this receiver by
// construction; a level shipped from the phone would need the same latency machinery
// `reactive-eq.md` §6c had to build, over a link whose delay nobody measures.
//
// **Five bands, the same as the phone**, since the menu-bar mark moved to the caption cut on
// 2026-09-02 (`BlindsEqMark.swift`'s `eqRestH` has the arithmetic). Bands must equal slats, so the
// count is *taken from the mark* rather than written here. Every constant that follows from it is
// derived below by the same formulae `EqAnalyser.kt` uses, which is what makes changing the slat
// count a one-line change on either side: at five bands over 60 Hz-12 kHz the spacing is 1.91
// octaves and the tiling condition gives Q 0.452, exactly what the phone reports in `eq.filters`.
//
// **What is deliberately not ported:** the presentation-time ring, the lead measurement, the
// `onAudioPositionAdvancing` stamp and the 700 ms clamp. All of those exist on the phone because
// its analyser sees a buffer before `AudioTrack` plays it. Here the tap is on the player node, so
// the audio reaching this class is the audio leaving the speaker.

import Accelerate
import Foundation
import QuartzCore

/// Fixed-size, allocation-free per buffer: the tap block runs on a render thread.
final class EqAnalyser {

    // MARK: - the shape, all derived

    /// Must equal `BlindsEqMark`'s slat count, and takes it from there rather than repeating the
    /// number — `EqAnalyserCheck` asserts the two agree, because a mismatch draws an equalizer with
    /// bars nothing drives and does not crash.
    static let bands = blindsEqSlats

    private static let loHz: Float = 60
    private static let hiHz: Float = 12_000
    /// Skirt steepness against work: `stages * 6 dB/octave` outside the passband. Two, as the app.
    private static let stages = 2

    /// Octaves between adjacent centres — `bands` centres span `log2(hi/lo)`, so `bands - 1` gaps.
    static let spacingOctaves = log2(hiHz / loHz) / Float(bands - 1)

    /// Q for passbands that meet at their −3 dB edges, so the spectrum is covered exactly once.
    ///
    /// A cascade of `stages` identical 2nd-order sections is −3 dB where
    /// `Q*u = sqrt(2^(1/stages) - 1)`, `u = f/f0 - f0/f`; tiling puts the upper edge one half
    /// spacing above centre, so `r = 2^(spacing/2)` and `u = r - 1/r`.
    ///
    /// **0.452, matching the phone** now that both marks carry five slats — but it is derived on
    /// both sides rather than copied, so a slat count that changes on one surface only still gets
    /// the right Q there. `scripts/eq-lab.html` fitting at a Q the app did not use is what a
    /// hand-picked one actually cost (`reactive-eq.md` §6m).
    static let bandQ: Float = {
        let r = powf(2, spacingOctaves / 2)
        return sqrtf(powf(2, 1 / Float(stages)) - 1) / (r - 1 / r)
    }()

    /// Log-spaced centres, lowest first — band 0 is the bass and drives the *bottom* slat.
    private static let centres: [Float] = {
        let step = logf(hiHz / loHz) / Float(bands - 1)
        return (0..<bands).map { loHz * expf(step * Float($0)) }
    }()

    // MARK: - the mapping, mirroring EqAnalyser.kt

    /// **How wide a swing fills a slat**, once a band is centred on its own recent level. Not a
    /// floor and a ceiling: the mapping is relative, so only the width matters. 16 dB, measured on
    /// the phone's side, where the mapping was tuned.
    private static let perBandWidthDb: Float = 16

    /// **The absolute ceiling under the relative mapping**, and why a noise floor is not read as
    /// music. Centring on a running mean has no cap of its own — hiss is as far from its own
    /// average as music is — so `She Left`'s −56..−61 dB opening drove a full bar until this
    /// existed. The only hand-picked pair left in this file; they want fitting, like the old
    /// window got.
    private static let absFloorDb: Float = -45
    private static let absCeilDb: Float = -25

    /// How long a band remembers its own level. **Short is deader, not livelier** — at 1 s the mean
    /// chases the music and a whole track's travel measured *below* the old global mapping. It
    /// plateaus at 6.
    private static let bandMemorySec: Float = 6
    /// What a silent band shows, so the mark never fully collapses mid-song.
    static let restingLevel: Float = 0.05

    /// Instant attack, 300→200 ms decay: see `reactive-eq.md` §6f and §6i. The 20 ms attack the
    /// phone once had was protecting against an 1800 ms decay that no longer exists.
    private static let attackMs: Float = 0
    private static let decayMs: Float = 200

    private static let agcTargetDb: Float = -14
    /// Linear, not exponential — "forgets N dB per second" is a number that can be reasoned about.
    private static let agcFallDbPerSec: Float = 4
    private static let gateDb: Float = -60
    /// **Derived, not chosen** (`reactive-eq.md` §6g): audio at the gate's own level then lands at
    /// exactly the floor and reads as rest, while anything louder rises in proportion. Lowering the
    /// gate *raises* this, which is why the two are one relationship.
    /// Re-anchored when the mapping went per-band: the old window started at −40 and gave 20 dB,
    /// the absolute term starts at [absFloorDb] and gives **15**. The lift reaches *only* that
    /// term — it cancels in the per-band half, whose mean tracks the lifted signal — and lifting
    /// both put `She Left` at 0.50 instead of 0.09.
    private static let agcMaxLiftDb = absFloorDb - gateDb

    /// **The auto-gain reads K-weighted loudness, the gate plain RMS**, as on the phone
    /// (`EqAnalyser.kt` at `KShelfHz`, 2026-10-18): plain RMS counts a bass-heavy master louder
    /// than it sounds. BS.1770's shelf then highpass, re-derived per rate, −0.691 so ~1 kHz reads
    /// at its RMS. Momentary, ungated, on the mono mix: not a LUFS meter.
    private static let kShelfHz = 1681.974450955533
    private static let kShelfDb = 3.999843853973347
    private static let kShelfQ = 0.7071752369554196
    private static let kHighpassHz = 38.13547087602444
    private static let kHighpassQ = 0.5003270373238773
    private static let kOffsetDb: Float = -0.691

    // MARK: - state

    private var coeff = [Float](repeating: 0, count: bands * 5)
    private var biquad = [Float](repeating: 0, count: bands * stages * 4)  // x1, x2, y1, y2
    private var levelsWork = [Float](repeating: restingLevel, count: bands)
    /// Scratch for one sub-block of mono samples. A sub-block can be up to *twice*
    /// `subBlockFrames` (the last one absorbs the remainder — see `onAudio`), and this was once
    /// sized to the nominal length only: at 192 kHz that wrote past the end of 4096. Sized for the
    /// highest rate the receiver accepts, so `reset` never allocates on the render thread.
    private var mono = [Float](repeating: 0, count: 2 * Int(384_000 / loHz))
    private var subBlockFrames = 0
    private var sampleRate: Float = 0
    private var agcRef: Float = -120
    /// The K-weighting's shelf then highpass, b0 b1 b2 a1 a2 each; double, because the
    /// highpass's poles sit within 0.01 of the unit circle.
    private var kCoeff = [Double](repeating: 0, count: 10)
    private var kState = [Double](repeating: 0, count: 8)  // x1, x2, y1, y2 per stage
    /// The last sub-block's K-weighted level, what the auto-gain read. Read by `eq-check`.
    private(set) var lastLoudnessDb: Float = -120
    /// Each band's own recent level in dB, an EMA over [bandMemorySec]. `nan` means "nothing yet",
    /// so a fresh track adopts its own first reading instead of ramping from a made-up one.
    private var bandMean = [Float](repeating: .nan, count: bands)
    /// Seconds of ungated audio [bandMean] has averaged. Until [bandMemorySec] of it the mean is
    /// the plain average so far, as on the phone (`EqAnalyser.kt`'s `bandMean`, 2026-10-18): a
    /// seeded EMA let one quiet first block hold every band full for ~5 s of a loud start.
    private var bandMeanSec: Float = 0

    /// A ring of level frames in **slat order**, each stamped with when it should be shown.
    ///
    /// **This is here because `installTap`'s `bufferSize` is a request the engine ignores.** It was
    /// asked for one sub-block (735 frames at 44.1 kHz) and delivers **4410 — 100 ms, ten callbacks
    /// a second**, measured 2026-09-02 by logging what actually arrived. Publishing one value per
    /// callback therefore drove the mark at 10 Hz however fast the display link ran, which is what
    /// "super sluggish, low fps" was.
    ///
    /// So each sub-block gets a presentation time and the reader walks them in order, exactly as
    /// the phone's ring does. The phone needed it for *latency* — its analyser sees a buffer before
    /// `AudioTrack` plays it — and this file said none of that machinery was needed here because
    /// the tap is at render time. True for latency, false for **rate**: a 100 ms burst still has to
    /// be shown over 100 ms.
    ///
    /// Slat order rather than band order because the analyser is the side that knows what a band
    /// means; getting that backwards once shipped a mark whose bass drove the hairlines (§6b).
    private static let ringFrames = 64
    private var ringLevels = [CGFloat](repeating: CGFloat(restingLevel), count: ringFrames * bands)
    private var ringStamp = [Double](repeating: 0, count: ringFrames)
    private var ringWrite = 0
    private var lastShown = [CGFloat](repeating: CGFloat(restingLevel), count: bands)
    private let lock = NSLock()
    /// Guards the filter, gain and mean state that `onAudio` runs on. Separate from `lock`, which
    /// guards only the ring the main thread reads.
    private let dspLock = NSLock()

    /// Nil until audio has been seen at all — the caller falls back to the canned walk, exactly as
    /// `BlindsEqMark` does when `EqAnalyser.levels()` returns null. A *quiet* passage returns
    /// resting levels instead; those are different things and conflating them was §6d's bug.
    private var hasAudio = false

    // MARK: - input

    /// Called from the player node's tap, on a render thread. Interleaved or planar float, as
    /// `AVAudioPCMBuffer` hands it over.
    func onAudio(_ samples: UnsafePointer<UnsafeMutablePointer<Float>>,
                 channels: Int, frames: Int, rate: Float) {
        guard frames > 0, channels > 0, rate > 0 else { return }
        // **The DSP state has one writer at a time.** Two render threads can call this for a
        // moment (a replaced session's engine winding down), and `standDown` resets from main.
        // `try`, never `lock`, on a render thread: a buffer skipped while another holds it costs
        // the mark one update; blocking here would cost an audio glitch.
        guard dspLock.try() else { return }
        defer { dspLock.unlock() }
        if rate != sampleRate { reset(rate: rate) }

        // The tap fires as this buffer is rendered, so its audio is heard over roughly the next
        // `frames / rate` seconds. Stamping each sub-block forward from here is what spreads a
        // 100 ms delivery across 100 ms of display instead of collapsing it to one update.
        let bufferStart = CACurrentMediaTime()
        var offset = 0
        while offset < frames {
            // The last sub-block absorbs the remainder rather than being a short one: an RMS over
            // a fraction of a bass cycle reads high or low depending only on where in the cycle it
            // fell, which is exactly what deriving the length from `rate / loHz` exists to prevent
            // (`reactive-eq.md` §6i).
            var n = subBlockFrames
            if frames - offset < 2 * subBlockFrames { n = frames - offset }
            processSubBlock(samples, channels: channels, from: offset, count: n,
                            showAt: bufferStart + Double(offset) / Double(rate))
            offset += n
        }
    }

    private func reset(rate: Float) {
        sampleRate = rate
        subBlockFrames = max(1, Int(rate / Self.loHz))
        if mono.count < 2 * subBlockFrames { mono = [Float](repeating: 0, count: 2 * subBlockFrames) }
        // A format change is a discontinuity, so the filter state goes — carrying it across one is
        // what made a restart read the previous passage's ringing (`reactive-eq.md` §6j).
        for i in biquad.indices { biquad[i] = 0 }
        for i in kState.indices { kState[i] = 0 }
        // With the filter state: a mean describes the audio that made it, and a format change
        // means that audio is gone.
        for i in bandMean.indices { bandMean[i] = .nan }
        bandMeanSec = 0
        agcRef = -120
        for i in levelsWork.indices { levelsWork[i] = Self.restingLevel }

        for i in 0..<Self.bands {
            // RBJ bandpass, constant skirt gain. Nyquist-clamped so a low rate cannot put a centre
            // above it and a NaN with it.
            let f0 = min(Self.centres[i], rate / 2 - 1)
            let w0 = 2 * Float.pi * f0 / rate
            let alpha = sinf(w0) / (2 * Self.bandQ)
            let a0 = 1 + alpha
            coeff[i * 5 + 0] = alpha / a0
            coeff[i * 5 + 1] = 0
            coeff[i * 5 + 2] = -alpha / a0
            coeff[i * 5 + 3] = (-2 * cosf(w0)) / a0
            coeff[i * 5 + 4] = (1 - alpha) / a0
        }

        let r = Double(rate)
        var k = tan(Double.pi * Self.kShelfHz / r)
        let vh = pow(10, Self.kShelfDb / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / Self.kShelfQ + k * k
        kCoeff[0] = (vh + vb * k / Self.kShelfQ + k * k) / a0
        kCoeff[1] = 2 * (k * k - vh) / a0
        kCoeff[2] = (vh - vb * k / Self.kShelfQ + k * k) / a0
        kCoeff[3] = 2 * (k * k - 1) / a0
        kCoeff[4] = (1 - k / Self.kShelfQ + k * k) / a0
        k = tan(Double.pi * Self.kHighpassHz / r)
        a0 = 1 + k / Self.kHighpassQ + k * k
        kCoeff[5] = 1; kCoeff[6] = -2; kCoeff[7] = 1
        kCoeff[8] = 2 * (k * k - 1) / a0
        kCoeff[9] = (1 - k / Self.kHighpassQ + k * k) / a0
    }

    private func processSubBlock(_ samples: UnsafePointer<UnsafeMutablePointer<Float>>,
                                 channels: Int, from: Int, count: Int, showAt: Double) {
        guard count > 0 else { return }
        // Downmix to mono once, rather than per band: the bank reads `bands * stages` biquads over
        // these samples and would otherwise pay the channel loop every time.
        mono.withUnsafeMutableBufferPointer { m in
            if channels == 1 {
                for k in 0..<count { m[k] = samples[0][from + k] }
            } else {
                let scale = 1 / Float(channels)
                for k in 0..<count {
                    var acc: Float = 0
                    for c in 0..<channels { acc += samples[c][from + k] }
                    m[k] = acc * scale
                }
            }
        }

        var broadband: Float = 0
        mono.withUnsafeBufferPointer { m in
            vDSP_rmsqv(m.baseAddress!, 1, &broadband, vDSP_Length(count))
        }
        let blockDb = dbOf(broadband)
        var kSum = 0.0
        mono.withUnsafeBufferPointer { m in
            for n in 0..<count {
                var v = Double(m[n])
                for st in 0..<2 {
                    let c = st * 5, p = st * 4
                    let y = kCoeff[c] * v + kCoeff[c + 1] * kState[p] + kCoeff[c + 2] * kState[p + 1]
                        - kCoeff[c + 3] * kState[p + 2] - kCoeff[c + 4] * kState[p + 3]
                    kState[p + 1] = kState[p]; kState[p] = v
                    kState[p + 3] = kState[p + 2]; kState[p + 2] = y
                    v = y
                }
                kSum += v * v
            }
        }
        let loudnessDb = dbOf(Float((kSum / Double(count)).squareRoot())) + Self.kOffsetDb
        lastLoudnessDb = loudnessDb

        // The reference follows the block instantly upward and falls linearly, so "forgets N dB a
        // second" describes it exactly.
        let dt = Float(count) / sampleRate
        if loudnessDb > agcRef { agcRef = loudnessDb }
        else { agcRef = max(-120, agcRef - Self.agcFallDbPerSec * dt) }
        let lift = min(max(Self.agcTargetDb - agcRef, 0), Self.agcMaxLiftDb)

        hasAudio = true

        if blockDb < Self.gateDb {
            // Digital silence costs one broadband RMS rather than `bands * stages` biquads — and it
            // reads as rest, not as null. Silence looks like silence (§6d); it is not masked.
            for i in 0..<Self.bands { levelsWork[i] = ballistics(levelsWork[i], Self.restingLevel, dt) }
            publish(at: showAt)
            return
        }

        bandMeanSec += dt
        let meanWeight = max(1 - expf(-dt / Self.bandMemorySec), dt / max(bandMeanSec, dt))
        for i in 0..<Self.bands {
            // Raw, no lift: the lift belongs to the guard alone (see [agcMaxLiftDb]), and adding it
            // here would cancel anyway since [bandMean] tracks whatever this produces.
            let bandDb = dbOf(bandRms(i, count: count))
            bandMean[i] = bandMean[i].isNaN ? bandDb
                : bandMean[i] + (bandDb - bandMean[i]) * meanWeight
            let target = levelFor(bandDb, mean: bandMean[i], lift: lift)
            levelsWork[i] = ballistics(levelsWork[i], target, dt)
        }
        publish(at: showAt)
    }

    /// One band: `stages` cascaded biquads over the sub-block, then RMS of the output. The filter
    /// state persists across sub-blocks, which is what makes a bandpass a bandpass.
    private func bandRms(_ i: Int, count: Int) -> Float {
        let b0 = coeff[i * 5 + 0], b1 = coeff[i * 5 + 1], b2 = coeff[i * 5 + 2]
        let a1 = coeff[i * 5 + 3], a2 = coeff[i * 5 + 4]
        var acc: Float = 0
        mono.withUnsafeBufferPointer { m in
            for k in 0..<count {
                var x = m[k]
                for s in 0..<Self.stages {
                    let base = (i * Self.stages + s) * 4
                    let x1 = biquad[base + 0], x2 = biquad[base + 1]
                    let y1 = biquad[base + 2], y2 = biquad[base + 3]
                    let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                    biquad[base + 1] = x1; biquad[base + 0] = x
                    biquad[base + 3] = y1; biquad[base + 2] = y
                    x = y
                }
                acc += x * x
            }
        }
        return sqrtf(acc / Float(count))
    }

    /// A band's dB → 0...1, as `min(shape, ceiling)`.
    ///
    /// `shape` is where this band sits against its own recent level, which is what makes the
    /// treble slat move as much as the bass one instead of being a permanent stub. `ceiling` is
    /// what the band's *absolute* level warrants, and it is the half that keeps a noise floor at
    /// rest — the relative term alone cannot tell hiss from music.
    private func levelFor(_ db: Float, mean: Float, lift: Float) -> Float {
        let shape = 0.5 + (db - mean) / Self.perBandWidthDb
        let ceiling = (db + lift - Self.absFloorDb) / (Self.absCeilDb - Self.absFloorDb)
        let t = min(max(min(shape, ceiling), 0), 1)
        return t * (1 - Self.restingLevel) + Self.restingLevel
    }

    /// Instant attack, exponential decay over `decayMs`.
    private func ballistics(_ current: Float, _ target: Float, _ dt: Float) -> Float {
        if target >= current {
            guard Self.attackMs > 0 else { return target }
            let k = 1 - expf(-dt * 1000 / Self.attackMs)
            return current + (target - current) * k
        }
        let k = 1 - expf(-dt * 1000 / Self.decayMs)
        return current + (target - current) * k
    }

    private func publish(at when: Double) {
        lock.lock()
        let slot = ringWrite % Self.ringFrames
        let base = slot * Self.bands
        for i in 0..<Self.bands {
            // Band order → slat order. Band 0 is the bass and belongs on the bottom slat, which is
            // the last of `eqCenters`.
            ringLevels[base + Self.bands - 1 - i] = CGFloat(levelsWork[i])
        }
        // Monotonic: the reader scans backwards for the newest frame that is due, and would stop
        // early on a stamp out of order.
        ringStamp[slot] = max(when, ringWrite == 0 ? when : ringStamp[(ringWrite - 1) % Self.ringFrames] + 1e-6)
        ringWrite += 1
        lock.unlock()
    }

    private func dbOf(_ magnitude: Float) -> Float {
        magnitude <= 1e-9 ? -190 : 20 * log10f(magnitude)
    }

    // MARK: - output

    /// The current levels in slat order, or nil if no audio has ever been seen — which is the
    /// caller's cue to run the canned walk. Never nil merely because the music is quiet.
    func levels() -> [CGFloat]? {
        lock.lock()
        defer { lock.unlock() }
        guard hasAudio else { return nil }
        let now = CACurrentMediaTime()
        // Newest frame that is due. Walking back rather than forward so a full ring costs one pass
        // and the common case — the last frame written — exits immediately.
        var found = -1
        let count = min(ringWrite, Self.ringFrames)
        for back in 0..<count {
            let slot = (ringWrite - 1 - back + Self.ringFrames * 2) % Self.ringFrames
            if ringStamp[slot] <= now { found = slot; break }
        }
        // Nothing due yet — the whole ring is in the future, which happens for one buffer after a
        // flush. Hold the last frame shown rather than jumping to the newest, which would be the
        // collapse this ring exists to prevent.
        guard found >= 0 else { return lastShown }
        let base = found * Self.bands
        for i in 0..<Self.bands { lastShown[i] = ringLevels[base + i] }
        return lastShown
    }

    /// The most recently *computed* frame, ignoring when it is due to be shown.
    ///
    /// Not for the mark — that must read [levels], or a 100 ms delivery collapses back to one
    /// visible update. This exists for `EqAnalyserCheck`, which feeds a whole tone burst in a few
    /// milliseconds: every stamp lands in the future, so [levels] correctly reports that nothing
    /// is due yet and the DSP assertions would be testing the clock instead of the filter bank.
    func newestLevels() -> [CGFloat]? {
        lock.lock()
        defer { lock.unlock() }
        guard hasAudio, ringWrite > 0 else { return nil }
        let base = ((ringWrite - 1) % Self.ringFrames) * Self.bands
        return Array(ringLevels[base..<(base + Self.bands)])
    }

    /// Called when the stream stops, so the next connection starts from rest rather than from
    /// whatever the last track left behind.
    func standDown() {
        lock.lock()
        hasAudio = false
        for i in ringLevels.indices { ringLevels[i] = CGFloat(Self.restingLevel) }
        for i in lastShown.indices { lastShown[i] = CGFloat(Self.restingLevel) }
        ringWrite = 0
        lock.unlock()
        dspLock.lock()
        for i in levelsWork.indices { levelsWork[i] = Self.restingLevel }
        for i in bandMean.indices { bandMean[i] = .nan }
        bandMeanSec = 0
        agcRef = -120
        dspLock.unlock()
    }
}
