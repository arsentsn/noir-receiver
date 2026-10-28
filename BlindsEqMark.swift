// The app's now-playing mark (BlindsEqMark in LibraryChrome.kt), ported for the
// menu bar: the logo's seven slats playing equalizer. Every slat keeps its B7
// thickness for good — the three closed slats stay closed, the four open ones stay
// open — and only the lengths dance while audio flows ("beat-snap", 0.6× tempo).
// Play↔pause is the "Fuse": each slat's right edge travels between its dancing bar
// and its spot on the triangle's hypotenuse over one 450ms ease, per-slat polygons
// keeping the logo's angled ends, the dance easing through the whole morph.
//
// The centres, the tempo, the fuse and the mapping mirror LibraryChrome.kt — change
// them together. The **cut** deliberately does not, and that is the one difference to
// keep rather than tidy away: see eqRestH below.

import AppKit
import Combine
import QuartzCore

/// **Five slats at pitch 17, the caption cut — the same geometry the phone draws** (2026-09-02).
///
/// This carried seven at pitch 12 until then, on the argument below; the argument turns out to
/// favour five, which is why the two marks are now one. The menu bar is the most contrast-starved
/// surface the mark has — the image is `isTemplate`, so the system throws the ink away and redraws
/// it in the bar's own colour, on a *light* bar in light mode — and it is the smaller render, 18pt
/// against a 16dp row mark. `branding/identity-system.html` 02 sends tint and light grounds to the
/// **compensated 0.44** cut for exactly that. The caption cut's 5.5/12 is **0.46**, which is that
/// rule, not an exception to it.
///
/// And every dimension gets bigger rather than smaller. At 18pt on a Retina bar, 100 units are
/// 36 device pixels, so one unit is 0.36 px:
///
/// | | thin slat | thick slat | binding gap |
/// |---|---|---|---|
/// | seven at pitch 12 (3.5 / 8) | 1.26 px | 2.88 px | 1.44 px |
/// | **five at pitch 17 (5.5 / 12)** | **1.98 px** | **4.32 px** | **1.80 px** |
///
/// The predecessor B8 ramp (1.2 1.4 1.95 2.9 4.2 5.9 8) is what makes the case concretely: at
/// 18pt its thinnest slat came to 0.43 of a device pixel. Three of the seven bars were a grey
/// smudge, so the menu bar appeared to hold a four-bar equalizer. Five slats move further from
/// that edge, not closer to it.
///
/// Pitch 17 rather than 18 for the reason `ic_stat_noir.xml` moved: the middle slat sits on 50 and
/// the centres are symmetric about it, so the bottom centre is `50 + 2p` and the triangle's foot is
/// at 90 — a 12-unit slat needs `p <= 17` or it is drawn short. See `reactive-eq.md` §6l.
private let eqCenters: [CGFloat] = [16, 33, 50, 67, 84]
private let eqRestH: [CGFloat] = [5.5, 5.5, 12, 12, 12]
private let eqTempo: CGFloat = 0.6

/// How many slats the mark has, and therefore how many bands `EqAnalyser` must produce.
///
/// Derived from [eqCenters] rather than written as a literal: the count has now changed twice
/// (seven to five here, and seven to five on the phone before it), and a hardcoded number leaves
/// slots the draw loop never reads — which compiles, runs, and silently stops matching the mark.
let blindsEqSlats = eqCenters.count

/// Triangle right edge at height `y` — upper hypotenuse above the tip, lower below.
///
/// **Clamped to the left edge**, as the app's is: outside y 10..90 the raw formula returns a value
/// below 18, i.e. a right edge left of the slat's own left edge, which draws a self-intersecting
/// bowtie. There is no clip path here either — the triangle is implicit in this function — so
/// nothing else would catch it. See `reactive-eq.md` §6b.
private func eqEdge(_ y: CGFloat) -> CGFloat {
    max(18, y <= 50 ? 18 + (y - 10) * 1.75 : 18 + (90 - y) * 1.75)
}

/// Steps the dance at 60fps locked to the display, and stops stepping entirely once
/// paused *and* the fuse has landed, so an idle receiver costs nothing. Not
/// ObservableObject: MenuBarExtra ignores label-local observation, so frames go out
/// through [onFrame] to whoever owns the status item.
///
/// **Why 60, and why locked.** It was 30 on a bare `Timer`, which is not only half the
/// frames but unaligned ones: a timer fires at an arbitrary phase against the panel's
/// refresh, so frames land unevenly however many there are. A `CADisplayLink` capped at
/// 60 is phase-locked and adapts — 60 on a 60Hz screen, every other refresh on a 120Hz
/// one, and it follows the panel if that changes.
///
/// The rate is free to move because `step` integrates real elapsed time (`dt`), so no
/// constant here is tuned to a frame count. What it costs is not the drawing — one frame
/// renders in 0.017ms — but the menu bar scene update each image swap fences, measured at
/// ~13% of a WindowServer core per 30fps, so this doubles ~0.2W while music plays and
/// nothing at all while it doesn't. 120Hz was measured working (nothing coalesces: 119
/// pushed, 119 taken) and rejected: triple the cost of 30 for a difference invisible on
/// an 18pt icon, and no other menu bar app on the test machine animates at all.
final class EqEngine: NSObject {
    /// Called on the main thread after every step while the mark is moving.
    var onFrame: (() -> Void)?
    private var tick = 0
    /// Seeded at **rest**, not randomly: this array is drawn once before the first step lands, and
    /// a random seed put a frame of full-length bars at arbitrary lengths on screen every time the
    /// mark appeared. Same fix as the app's (`reactive-eq.md` §7).
    private(set) var levels = [CGFloat](repeating: CGFloat(EqAnalyser.restingLevel),
                                        count: blindsEqSlats)

    /// Set by the app once the receiver exists; nil in the preview harness, which has no audio and
    /// wants the canned walk. `levels()` returning nil means "no audio at all" and falls back to
    /// that walk — a *quiet* passage returns resting levels instead, and conflating the two is the
    /// bug `reactive-eq.md` §6d ends with a rule.
    var analyser: EqAnalyser?
    private(set) var blend: CGFloat = 0

    private var targets = (0..<blindsEqSlats).map { _ in CGFloat.random(in: 0...1) }
    private var next = [CGFloat](repeating: 0, count: blindsEqSlats)
    private var playing = false
    private var blendFrom: CGFloat = 0
    private var blendTarget: CGFloat = 0
    private var blendStart: CFTimeInterval = 0
    private var vt: CGFloat = 0
    private var lastStep: CFTimeInterval = 0
    /// The fallback frame source, used when there is no host view to hang a display link
    /// on (the preview harness) or on macOS 13, which has no `NSView.displayLink`.
    private var timer: Timer?
    /// A `CADisplayLink` on macOS 14+, typed loosely because a stored property cannot
    /// carry an availability annotation.
    private var link: AnyObject?
    private var stepping: Bool { timer != nil || link != nil }
    /// Whether frames are going out right now: true while playing, and for the fuse after.
    /// A title pass in the status item rides these frames and starts its own only when this is
    /// false (`AppDelegate.startPass`), so the two never double the image swaps.
    var isStepping: Bool { stepping }

    /// The view whose display drives the steps — the status item's button. Set by the app
    /// once the status item exists; leaving it nil falls back to a timer at the same rate.
    weak var frameHost: NSView?

    private static let targetFps: Double = 60

    private var sub: AnyCancellable?
    // App Nap coalesces a background LSUIElement app's timers to seconds — measured
    // freezing the dance several beats behind the audio. Held only while stepping.
    private var activity: NSObjectProtocol?

    init(receiver: Receiver) {
        super.init()
        sub = receiver.$live
            .map { $0?.playing ?? false }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.setPlaying($0) }
    }

    /// Whether the mark dances at all.
    ///
    /// Gated here rather than in the renderer so that "off" costs nothing: no timer,
    /// and no `beginActivity` holding the system out of idle sleep. The icon still
    /// means something with this off — it rests on the logo and keeps the dot badge,
    /// so "connected" is still readable, only "playing" stops being animated.
    var enabled = true {
        didSet {
            guard enabled != oldValue else { return }
            if enabled {
                if playing { fuse(to: 1) }
            } else {
                // Glide out on the same 450ms fuse a pause uses, rather than snapping
                // to the logo — switching the setting should look like the animation
                // it is turning off, not like the icon breaking. `step` stops the
                // stepper once this lands, so "off" still costs nothing a moment later.
                guard blend > 0 || stepping else { return }
                fuse(to: 0)
            }
        }
    }

    private func setPlaying(_ now: Bool) {
        guard now != playing else { return }
        playing = now
        guard enabled else { return } // state still tracked, so re-enabling catches up
        fuse(to: now ? 1 : 0)
    }

    /// Starts the 450ms play↔pause morph, and the stepper if it isn't already running.
    private func fuse(to target: CGFloat) {
        blendFrom = blend
        blendTarget = target
        blendStart = CACurrentMediaTime()
        vt = 0
        for i in next.indices { next[i] = CGFloat(i) * 0.03 } // staggered first moves
        startStepping()
    }

    private func startStepping() {
        guard !stepping else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "now-playing mark animation")
        lastStep = CACurrentMediaTime()

        if #available(macOS 14.0, *), let host = frameHost {
            let displayLink = host.displayLink(target: self, selector: #selector(displayStep))
            // A range rather than one number: the link picks a divisor of the panel's
            // actual refresh, so this is 60 on a 60Hz screen and every other frame on a
            // 120Hz one. The floor lets it drop to 30 rather than miss frames outright
            // if the system is under pressure — the dance is time-integrated, so a
            // sparser sampling slows nothing down, it only looks coarser.
            displayLink.preferredFrameRateRange =
                CAFrameRateRange(minimum: 30, maximum: Float(Self.targetFps),
                                 preferred: Float(Self.targetFps))
            displayLink.add(to: .main, forMode: .common)
            link = displayLink
        } else {
            timer = Timer.scheduledTimer(withTimeInterval: 1 / Self.targetFps,
                                         repeats: true) { [weak self] _ in
                self?.step()
            }
        }
    }

    /// The display link's target has to be `@objc`, which is the only reason this class
    /// inherits `NSObject`.
    @objc private func displayStep() {
        step()
    }

    private func stopStepping() {
        timer?.invalidate()
        timer = nil
        if #available(macOS 14.0, *), let displayLink = link as? CADisplayLink {
            displayLink.invalidate()
        }
        link = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func step() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - lastStep, 0.1))
        lastStep = now

        let p = CGFloat(min(1, (now - blendStart) / 0.45))
        blend = blendFrom + (blendTarget - blendFrom) * (p * p * (3 - 2 * p)) // smoothstep ≈ FastOutSlowIn

        let sdt = dt * eqTempo
        vt += sdt
        // The audio this Mac is emitting, when there is any. The analyser owns the ballistics, so
        // the levels are taken whole rather than eased towards — easing them again here would be a
        // second decay on top of the one that was tuned.
        if let live = analyser?.levels(), live.count == levels.count {
            levels = live
        } else {
            for i in levels.indices {
                // No new targets once paused, or once switched off — the bars glide out on
                // their way to the triangle rather than picking fresh moves.
                if playing, enabled, vt > next[i] {
                    targets[i] = .random(in: 0...1)
                    next[i] = vt + 0.12 + .random(in: 0...0.1)
                }
                levels[i] += (targets[i] - levels[i]) * min(1, sdt * 16)
            }
        }
        tick &+= 1
        onFrame?()

        // Stop once the fuse has landed and there is nothing left to animate: either
        // paused, or switched off. Testing `!playing` alone would leave the timer
        // running forever when the setting is turned off mid-song.
        if p >= 1, !playing || !enabled { stopStepping() }
    }
}

/// Renders one frame of the mark as a template NSImage — MenuBarExtra's label
/// slot only honours Text and Image, so animation is "swap the image each tick",
/// the standard status-item approach. `flipped: true` gives a y-down context,
/// matching the app's Canvas coordinates verbatim.
func eqMarkImage(levels: [CGFloat], blend e: CGFloat, connected: Bool) -> NSImage {
    let side: CGFloat = 18
    let img = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        ctx.setFillColor(NSColor.black.cgColor)
        drawEqMark(in: ctx, rect: rect, levels: levels, blend: e, connected: connected)
        return true
    }
    img.isTemplate = true
    return img
}

/// The mark into `rect` of a y-down context, in the current fill colour. Split out of
/// `eqMarkImage` so the status item can draw it beside the song (`menuBarImage`) without a second
/// copy of the geometry.
func drawEqMark(in ctx: CGContext, rect: CGRect, levels: [CGFloat], blend e: CGFloat,
                connected: Bool) {
    let u = rect.width / 100
    // Same optical mapping as the app's mark: recentre on (53, 50), 1.12×.
    func mx(_ x: CGFloat) -> CGFloat { rect.minX + (50 + (x - 53) * 1.12) * u }
    func my(_ y: CGFloat) -> CGFloat { rect.minY + (50 + (y - 50) * 1.12) * u }
    func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    for i in eqCenters.indices {
        let h = eqRestH[i]
        let y1 = eqCenters[i] - h / 2
        let y2 = eqCenters[i] + h / 2
        // Right edge: the slat's spot on the hypotenuse at e=0 (angled ends,
        // pentagon tip on the middle slat), the dancing bar at e=1.
        let xd = 18 + 6 + 64 * levels[i]
        let xT = lerp(eqEdge(y1), xd, e)
        let xB = lerp(eqEdge(y2), xd, e)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: mx(18), y: my(y1)))
        path.addLine(to: CGPoint(x: mx(xT), y: my(y1)))
        if y1 < 50, y2 > 50 { path.addLine(to: CGPoint(x: mx(lerp(88, xd, e)), y: my(50))) }
        path.addLine(to: CGPoint(x: mx(xB), y: my(y2)))
        path.addLine(to: CGPoint(x: mx(18), y: my(y2)))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.fillPath()
    }
    if connected {
        // Sized for the 18pt mark; scaled with a smaller one so it stays a badge, not a blot.
        let d = 4 * rect.width / 18
        ctx.fillEllipse(in: CGRect(x: rect.maxX - d - 0.5 * rect.width / 18,
                                   y: rect.maxY - d - 0.5 * rect.width / 18, width: d, height: d))
    }
}

