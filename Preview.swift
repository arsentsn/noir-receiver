// Renders the popover and the settings window offscreen, and prints the size each one
// wants. Build and run with `./build.sh preview && ./preview`.
//
// It exists because of one specific bug class that code review does not catch and a
// running app shows only after you click: a child view leaking its intrinsic width up
// the tree. `MarqueeText` did exactly that — two `fixedSize()` copies of a long title
// under a `.clipped()`, which clips drawing but not layout, so the whole popover took
// the untruncated title's width and every row ended up cut off on both edges. The
// assertion that would have caught it is one integer: fittingSize.width.
//
// The views are the real ones. The Receiver is real, and is driven over a real socket
// with the real protocol, so what gets measured is what ships. Only the entry point
// differs, which is why `@main` lives alone in NoirReceiverMain.swift.
//
// Since 2026-09-04 it also drives the pairing path end to end, because that path has no
// other instrument: a fake phone connects with approval on, the popover is measured in its
// "wants to play" state, the phone is allowed and must receive `pending` then `approved`;
// a second phone with the *same name* but its own id must be asked rather than let in (the hole
// a name key had until 2026-10-13), and is denied: `declined`, then a FIN. The CLI cannot do
// any of this (approval is off there, and there is nothing to click), and the real app
// needs a human at the popover.
//
// **Steps wait for a condition, never for a fixed delay.** The first version slept 1.5 s,
// 1.0 s and 0.6 s between steps and reported three failures on 2026-09-05 that were not the
// receiver's: `engine.start()` had stalled on a contended audio device right after a rebuild
// (the trap `protocol-test.py`'s `settle()` exists for), so the popover was measured before
// the allowed phone's state had landed. `eventually` polls for what the step actually needs
// and gives up loudly after a timeout, so a slow device is a slower pass and a broken
// receiver is still a failure.

import AppKit
import Network
import SwiftUI

private let previewPort: UInt16 = 40590

/// Wider than this and something has leaked its intrinsic size upward.
private let popoverWidthLimit: CGFloat = 320
private let settingsWidthLimit: CGFloat = 420

private let longTitle = "911 / Mr. Lonely (feat. Frank Ocean & Steve Lacy) - Extended Mix"
private let phoneName = "Sam’s Galaxy"

@main
struct Preview {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let receiver = Receiver(port: previewPort, prebufferMs: 200)
        receiver.log = { line in FileHandle.standardError.write(("  recv: " + line + "\n").data(using: .utf8)!) }
        receiver.logListening = receiver.log
        // The app's default, and the state this harness has to exercise: nothing plays until
        // somebody clicks Allow.
        receiver.requireApproval = true
        receiver.start()

        let phone = FakePhone(name: phoneName)
        phone.connect()

        let engine = EqEngine(receiver: receiver)
        var failures = 0
        func expect(_ ok: Bool, _ what: String) {
            print("\(ok ? "ok  " : "FAIL") \(what)")
            if !ok { failures += 1 }
        }

        // 1. The phone has identified itself and is waiting. Measure the popover as it asks.
        eventually(5, { receiver.pendingApproval != nil }) {
            expect(receiver.pendingApproval?.displayName == phoneName,
                   "pairing: \(phoneName) is asking (got \(receiver.pendingApproval?.displayName ?? "nobody"))")
            expect(receiver.phone == nil, "pairing: nothing is live while it asks")
            expect(phone.statuses == [ApprovalStatus.pending.rawValue],
                   "pairing: the phone was told 'pending' and nothing else (got \(phone.statuses))")
            failures += measure("popover (asking)", ReceiverMenu(receiver: receiver),
                                limit: popoverWidthLimit, file: "popover-asking.png")

            receiver.allow()
            expect(receiver.knownPhones[phone.key] == true, "pairing: Allow is remembered by the phone's id")
            expect(receiver.displayName(ofKnown: phone.key) == phoneName,
                   "pairing: Settings shows the remembered phone by name")
            expect(receiver.pendingApproval == nil, "pairing: the request clears on Allow")
            // Audio only now — everything sent while it waited was dropped by design, and the
            // dance check below needs sound to be draining when it runs.
            phone.sendAudio(seconds: 9)

            // 2. A stranger with the same name asks while the first phone plays, and is denied.
            let stranger = FakePhone(name: phoneName)
            stranger.connect()
            eventually(5, { receiver.pendingApproval?.key == stranger.key && receiver.deviceName == phoneName }) {
                expect(receiver.pendingApproval?.key == stranger.key,
                       "pairing: a stranger with the same name is asked, not let in "
                       + "(got \(receiver.pendingApproval?.key ?? "nobody"))")
                expect(receiver.deviceName == phoneName,
                       "pairing: the allowed phone stays live while a stranger asks")
                receiver.deny()
                expect(receiver.knownPhones[stranger.key] == false, "pairing: Deny is remembered by id")
                expect(receiver.knownPhones[phone.key] == true, "pairing: the twin's Deny leaves the Allow alone")
                eventually(5, { stranger.closedByReceiver && stranger.statuses.count >= 2
                                && receiver.nowPlaying != nil && receiver.playing }) {
                    expect(stranger.statuses == [ApprovalStatus.pending.rawValue, ApprovalStatus.declined.rawValue],
                           "pairing: the stranger was told 'pending' then 'declined' (got \(stranger.statuses))")
                    expect(stranger.closedByReceiver, "pairing: the stranger's connection was closed from this end")
                    expect(phone.statuses == [ApprovalStatus.pending.rawValue, ApprovalStatus.approved.rawValue],
                           "pairing: the allowed phone was told 'approved' (got \(phone.statuses))")
                    expect(receiver.deviceName == phoneName && receiver.nowPlaying != nil,
                           "pairing: the allowed phone is still the live one after the denial")

                    // 3. The ordinary measurements, on a receiver now streaming from an allowed phone.
                    failures += measure("popover", ReceiverMenu(receiver: receiver),
                                        limit: popoverWidthLimit, file: "popover.png")
                    failures += measure("settings", SettingsView(receiver: receiver),
                                        limit: settingsWidthLimit, file: "settings.png")
                    if receiver.nowPlaying == nil {
                        print("FAIL metadata: none arrived — the popover was measured empty")
                        failures += 1
                    }
                    failures += markSheet(engine, file: "mark.png")
                    menuBarSheet(file: "menubar.png")

                    checkAnimationToggle(engine) { animationFailures in
                        failures += animationFailures
                        print("")
                        print(failures == 0 ? "all ok" : "\(failures) problem(s)")
                        exit(failures == 0 ? 0 : 1)
                    }
                }
            }
        }

        app.run()
    }
}

/// Runs `then` once `condition` holds, polling every 50 ms on main — or after `timeout`,
/// so the step's own assertions report what was still missing instead of the harness hanging.
@MainActor
private func eventually(_ timeout: TimeInterval, _ condition: @escaping () -> Bool,
                        then: @escaping () -> Void) {
    let deadline = Date().addingTimeInterval(timeout)
    func poll() {
        if condition() || Date() >= deadline { then(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() }
    }
    poll()
}

/// Checks that the menu bar mark stops stepping when the animation setting goes off.
///
/// The failure this exists for is invisible and expensive: `step()` only stopped the
/// timer when playback was *paused*, so switching the setting off mid-song would have
/// left the frame source running forever — a 60fps timer, or a display link firing every
/// other refresh — with a `PreventUserIdleSystemSleep` assertion held the whole time.
/// Nothing on screen would have shown it. The signal is simply whether `onFrame` keeps
/// firing.
///
/// Note this exercises the *timer* path: the harness has no status item, so there is no
/// host view for a display link. The shipping path is checked separately, since a link
/// that never invalidates is the same bug wearing a different hat.
@MainActor
private func checkAnimationToggle(_ engine: EqEngine, done: @escaping (Int) -> Void) {
    var frames = 0
    engine.onFrame = { frames += 1 }

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
        let dancing = frames > 5
        print(dancing
              ? "ok   engine: dancing while audio plays (\(frames) frames)"
              : "FAIL engine: only \(frames) frames while audio plays — nothing to switch off")

        let atToggle = frames
        engine.enabled = false
        // Long enough for the 450ms fuse-out to land and the timer to be released.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let settled = frames
            let rested = engine.blend == 0
            // ~450ms at 60fps is ~27 frames. A snap to the logo would be one. The bound stays
            // at 8 so this passes on the timer fallback too.
            let fuseFrames = settled - atToggle
            let fused = fuseFrames >= 8
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let after = frames - settled
                print(fused
                      ? "ok   engine: faded out over \(fuseFrames) frames, not a snap"
                      : "FAIL engine: only \(fuseFrames) frames switching off — it snapped")
                print(after == 0
                      ? "ok   engine: timer released after switching off"
                      : "FAIL engine: still stepping (\(after) frames in 1s) after switching off")
                print(rested
                      ? "ok   engine: settled on the resting logo (blend 0)"
                      : "FAIL engine: blend \(engine.blend) after the fuse should have landed")
                done((dancing ? 0 : 1) + (fused ? 0 : 1) + (after == 0 ? 0 : 1) + (rested ? 0 : 1))
            }
        }
    }
}

/// Writes a contact sheet of the menu bar mark and checks its thinnest slat is drawable.
///
/// The mark is the receiver's most visible surface and, until this existed, the only one the
/// harness could not show: the popover and the settings window get a PNG each, while the thing
/// in the menu bar could be judged only by launching the app and squinting at an 18pt glyph.
/// That is how B7 arrived. Under the old B8 ramp the three thinnest slats came to under half a
/// device pixel at 18pt, so the menu bar held what looked like a four-bar equalizer, and no
/// amount of reading the code says that — it is a number about a size, and the size lives here.
///
/// Both grounds and both states, because that is what the cut is answering. `eqMarkImage`
/// returns a *template* image: the system throws its ink away and repaints it in the menu bar's
/// colour, which is near-black on a light bar in light mode and near-white on a dark one. The
/// sheet draws it each way, at 18pt and at 8x, so "does the thin group survive" is a look rather
/// than an argument.
@MainActor
private func markSheet(_ engine: EqEngine, file: String) -> Int {
    let states: [(String, CGFloat)] = [("resting", 0), ("playing", 1)]
    let sizes: [CGFloat] = [18, 18 * 8]
    let pad: CGFloat = 12
    // Two tiles per size — the light menu bar and the dark one.
    let width = sizes.reduce(0) { $0 + $1 * 2 } + pad * CGFloat(sizes.count * 2 + 1)
    let tall = sizes.max()!
    let height = CGFloat(states.count) * (tall + pad) + pad

    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2),
                              pixelsHigh: Int(height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                              hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setFillColor(NSColor.gray.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    var y = height - pad
    for (_, blend) in states {
        y -= tall
        var x = pad
        for side in sizes {
            let image = eqMarkImage(levels: engine.levels, blend: blend, connected: true)
            for (ground, ink) in [(NSColor.white, NSColor.black), (NSColor.black, NSColor.white)] {
                let box = CGRect(x: x, y: y + (tall - side), width: side, height: side)
                ctx.setFillColor(ground.cgColor)
                ctx.fill(box)
                // The tint has to happen in a layer of its own. `sourceIn` keeps the fill only
                // where the destination is opaque, and the destination here already holds the
                // ground -- so tinting straight onto it paints the whole tile. The layer starts
                // empty, so the only thing in it to keep is the glyph.
                ctx.saveGState()
                ctx.clip(to: box)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                image.draw(in: box)
                ctx.setBlendMode(.sourceIn)
                ctx.setFillColor(ink.cgColor)
                ctx.fill(box)
                ctx.endTransparencyLayer()
                ctx.restoreGState()
                x += side + pad
            }
        }
        y -= pad
    }
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])?
        .write(to: URL(fileURLWithPath: file))

    // The mapping in eqMarkImage: my(y) = (50 + (y - 50) * 1.12) * side / 100, so a slat's drawn
    // thickness is height * 1.12 * side / 100, doubled for a 2x panel.
    let closed = BlindsGlyph.Cut.compensated.bars[0]
    let px = (closed.1 - closed.0) * 1.12 * 18 / 100 * 2
    let ok = px >= 1
    print("\(ok ? "ok  " : "FAIL") mark: thinnest slat \(String(format: "%.2f", px))px at 18pt on a 2x panel"
          + (ok ? " — \(file)" : " — under one pixel; it will render as a smudge, not a slat"))
    return ok ? 0 : 1
}

/// Writes every shape the status item can take, on the light bar and the dark one, at twice
/// Retina size: icon, icon over the line, the song short and long, still and mid-scroll. A look,
/// not an assertion — what it answers ("does the line crowd the mark", "does the fade read") is
/// a judgement about pixels, and the pixels are only here.
@MainActor
private func menuBarSheet(file: String) {
    let short = "Blue Monday · New Order"
    let long = "911 / Mr. Lonely (feat. Frank Ocean & Steve Lacy) · Tyler, the Creator"
    // (text, scroll, progress, blend): the resting logo and a mid-dance frame both, since the
    // line sits under whichever the mark is showing.
    let frames: [(String?, CGFloat?, CGFloat?, CGFloat)] = [
        (nil, nil, nil, 0), (nil, nil, 0.35, 0), (nil, nil, 0.35, 1),
        (short, nil, nil, 0), (short, nil, 0.35, 1),
        (long, nil, 0.6, 0), (long, 4, 0.6, 1), (long, 60, 0.6, 1),
    ]
    // Fixed rather than the engine's, which has settled at rest by now and would draw the dance
    // as five stubs.
    let dancing: [CGFloat] = [0.55, 0.9, 0.7, 0.95, 0.45]
    // 22pt, the thinner bar of a Mac without a notch, and the one where the line is tightest.
    let bar: CGFloat = 22, zoom: CGFloat = 2, pad: CGFloat = 10
    let images = frames.map { text, scroll, progress, blend -> NSImage in
        var frame = MenuBarFrame(levels: dancing, blend: blend, connected: true)
        frame.text = text
        frame.scroll = scroll
        frame.progress = progress
        return menuBarImage(frame, height: bar,
                            textWidth: text.map(MenuBarLayout.textWidth))
    }
    let columnWidth = (images.map(\.size.width).max() ?? 0) * zoom + pad * 2
    let width = columnWidth * 2 + pad
    let height = CGFloat(images.count) * (bar * zoom + pad) + pad
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2),
                              pixelsHigh: Int(height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                              hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    for (column, (ground, ink)) in [(NSColor(white: 0.92, alpha: 1), NSColor.black),
                                    (NSColor(white: 0.12, alpha: 1), NSColor.white)].enumerated() {
        let x0 = CGFloat(column) * (columnWidth + pad)
        ctx.setFillColor(ground.cgColor)
        ctx.fill(CGRect(x: x0, y: 0, width: columnWidth + (column == 0 ? pad : 0), height: height))
        var y = height - pad
        for image in images {
            y -= bar * zoom
            let box = CGRect(x: x0 + pad, y: y, width: image.size.width * zoom, height: bar * zoom)
            // Tinted in a layer of its own, as in `markSheet`: the system repaints a template.
            ctx.saveGState()
            ctx.clip(to: box)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            image.draw(in: box)
            ctx.setBlendMode(.sourceIn)
            ctx.setFillColor(ink.cgColor)
            ctx.fill(box)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
            y -= pad
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
    print("     menu bar: every style — \(file)")
}

/// Measures a view's intrinsic size and writes a PNG of it.
///
/// Two renderer traps, both hit while building this. `cacheDisplay(in:to:)` captures
/// only AppKit's drawing path, so SwiftUI comes out as a blank page with the slider
/// knobs on it — use `ImageRenderer`. And `ImageRenderer` draws yellow no-entry
/// placeholders where AppKit-backed controls (Slider, TextField, Toggle) would be, so
/// the images are good for layout and text and useless for judging the controls.
@MainActor
private func measure(_ name: String, _ view: some View, limit: CGFloat, file: String) -> Int {
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(x: 0, y: 0, width: 1200, height: 1200)
    hosting.layoutSubtreeIfNeeded()
    let size = hosting.fittingSize

    let ok = size.width <= limit
    print("\(ok ? "ok  " : "FAIL") \(name): \(Int(size.width)) x \(Int(size.height))"
          + (ok ? "" : "  — wider than \(Int(limit)); something leaked its intrinsic width"))

    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    if let image = renderer.nsImage,
       let tiff = image.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: file))
    }
    return ok ? 0 : 1
}

/// Speaks the real protocol at our own listener: handshake, then the frames a popover
/// needs — and reads what comes back, which is how the status frames are asserted.
/// Deliberately a long title, so the marquee path is the one being measured.
///
/// Audio is sent separately (`sendAudio`), *after* the receiver has allowed the phone:
/// audio that arrives while it is waiting is dropped by design, and the dance check needs
/// sound to still be draining when it runs.
private final class FakePhone {
    let name: String
    /// A fresh id per instance, as two installs would have.
    let id = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    /// What the receiver remembers this phone by.
    var key: String { "id:" + id.map { String(format: "%02x", $0) }.joined() }
    private let connection: NWConnection
    /// Every `StatusFrame` byte received, in order. Appended on main, read on main.
    private(set) var statuses: [UInt8] = []
    /// True once the receiver sent a FIN — a denial's second half.
    private(set) var closedByReceiver = false

    init(name: String) {
        self.name = name
        connection = NWConnection(host: "127.0.0.1",
                                  port: NWEndpoint.Port(rawValue: previewPort)!,
                                  using: .tcp)
    }

    func connect() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            connection.send(content: Data("NOIR".utf8) + [1, 0, 0, 0], completion: .idempotent)
            connection.receive(minimumIncompleteLength: 8, maximumLength: 8) { [weak self] reply, _, _, _ in
                guard let self else { return }
                guard let reply, reply.count >= 8, reply[5] & CapControl != 0 else {
                    print("FAIL handshake: receiver did not offer CONTROL")
                    return
                }
                var out = Data("NOIR".utf8) + [1, CapControl, 0, 0]
                out += wavHeader()
                // The id first, as the phone sends it: the name is what settles identity.
                out += frame(Uplink.phoneId.rawValue, id)
                out += frame(Uplink.deviceName.rawValue, Data(name.utf8))
                out += frame(Uplink.nowPlaying.rawValue,
                             nowPlayingPayload(playing: true, title: longTitle,
                                               artist: "Tyler, the Creator",
                                               // Long on purpose, like the title: the album
                                               // line truncates rather than scrolling, and a
                                               // short one would never test that it does.
                                               album: "CALL ME IF YOU GET LOST — Deluxe Edition",
                                               year: 2021))
                out += frame(Uplink.position.rawValue, u32(63_000) + u32(224_000))
                out += frame(Uplink.artwork.rawValue, swatchJPEG())
                connection.send(content: out, completion: .idempotent)
                readDownlink()
            }
        }
        connection.start(queue: .global())
    }

    /// A quiet tone, in the 100 ms chunks a phone sends. Split into chunks rather than one
    /// frame because playback waits for the prebuffer's worth of *audio*, and the pacing of
    /// arrival is part of what the receiver is being driven with.
    func sendAudio(seconds: Double) {
        var out = Data()
        for chunk in toneChunks(seconds: seconds, chunkMs: 100) {
            out += frame(Uplink.audio.rawValue, chunk)
        }
        connection.send(content: out, completion: .idempotent)
    }

    /// `[type][len u32 LE][payload]`, the same shape the phone's reader parses.
    private func readDownlink() {
        connection.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] head, _, done, error in
            guard let self else { return }
            guard let head, head.count == 5 else {
                if done || error != nil { DispatchQueue.main.async { self.closedByReceiver = true } }
                return
            }
            var r = WireReader(head)
            guard let type = r.u8(), let length = r.u32().map(Int.init) else { return }
            let deliver: (Data) -> Void = { payload in
                if type == StatusFrame, let status = payload.first {
                    DispatchQueue.main.async { self.statuses.append(status) }
                }
                self.readDownlink()
            }
            if length == 0 { deliver(Data()); return }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { payload, _, _, _ in
                deliver(payload ?? Data())
            }
        }
    }
}

/// A quiet 440Hz tone, sliced the way a phone sends it. Audible enough for the receiver
/// to call itself playing, quiet enough not to make running the harness unpleasant.
private func toneChunks(seconds: Double, chunkMs: Double,
                        hz: Double = 440, rate: Double = 44_100) -> [Data] {
    let perChunk = Int(rate * chunkMs / 1000)
    var chunks: [Data] = []
    var n = 0
    let total = Int(rate * seconds)
    while n < total {
        var out = Data(capacity: perChunk * 4)
        for _ in 0..<min(perChunk, total - n) {
            let sample = Int16(2000 * sin(2 * .pi * hz * Double(n) / rate))
            out.appendLE(sample)   // left
            out.appendLE(sample)   // right
            n += 1
        }
        chunks.append(out)
    }
    return chunks
}

private func u32(_ value: UInt32) -> Data {
    var out = Data()
    out.appendLE(value)
    return out
}

private func u16(_ value: Int) -> Data {
    var out = Data()
    out.appendLE(UInt16(truncatingIfNeeded: value))
    return out
}

private func nowPlayingPayload(playing: Bool, title: String,
                               artist: String, album: String, year: Int) -> Data {
    var out = Data([playing ? 1 : 0])
    for text in [title, artist, album] {
        let bytes = Data(text.utf8)
        out += u16(bytes.count) + bytes
    }
    return out + u16(year)
}

private func wavHeader(rate: UInt32 = 44_100, channels: UInt16 = 2) -> Data {
    var out = Data("RIFF".utf8) + u32(0xFFFF_FFFF) + Data("WAVEfmt ".utf8)
    out += u32(16) + u16(1) + u16(Int(channels)) + u32(rate)
    out += u32(rate * UInt32(channels) * 2) + u16(Int(channels) * 2) + u16(16)
    out += Data("data".utf8) + u32(0xFFFF_FFFF)
    return out
}

/// A flat swatch, so the artwork path renders something without a binary in the repo.
private func swatchJPEG() -> Data {
    let image = NSImage(size: NSSize(width: 128, height: 128))
    image.lockFocus()
    NSColor.systemIndigo.setFill()
    NSRect(x: 0, y: 0, width: 128, height: 128).fill()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let jpeg = rep.representation(using: .jpeg, properties: [:]) else { return Data() }
    return jpeg
}
