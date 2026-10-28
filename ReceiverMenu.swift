// The popover's content, and the small views only it uses.

import AppKit
import SwiftUI

/// The popover: what is playing, and the controls for it. Nothing you set once.
///
/// Everything configurable moved to `SettingsView` in a real window — see
/// `AppDelegate.openSettings`. This kept the popover at the size of its job (about
/// 280x200 against 390 before) and, more usefully, got the port field out of a
/// `.transient` container that closed on every stray click.
struct ReceiverMenu: View {
    @ObservedObject var receiver: Receiver
    var onSettings: () -> Void = {}

    private var transportPlaying: Bool { receiver.nowPlaying?.playing ?? receiver.playing }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // A phone this Mac has not seen before. Shown above whatever is playing (a
            // known phone may be streaming while a stranger asks), and the tooltip carries
            // the same line for when the popover has been clicked away.
            if let request = receiver.pendingApproval {
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(request.displayName) wants to play on this Mac",
                          systemImage: "iphone.radiowaves.left.and.right")
                        // Same reason as the settings captions: a Label proposes one
                        // line, and a long device name must wrap rather than ellipsize.
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        // **Neither is the default button.** This popover opens itself when a
                        // phone asks, so Return — typed into whatever had focus — must not
                        // be the Allow.
                        Button("Allow") { receiver.allow() }
                        Button("Deny") { receiver.deny() }
                        Spacer()
                        Text("Remembered for next time")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Divider()
            }

            if let now = receiver.nowPlaying {
                // Mini-player shape: small art, then title, artist, album — the same
                // three lines in the same order as the phone's `TrackTitles`, with the
                // type stepping down the same way. Once you can see the song, "which
                // phone" stops being the headline — it moves to the caption at the
                // bottom with the format.
                HStack(spacing: 10) {
                    Artwork(image: receiver.artwork)
                    VStack(alignment: .leading, spacing: 1) {
                        // Titles overflow 280pt constantly — remixes, parentheticals,
                        // "(Jazz Version)" — so this row scrolls rather than truncates.
                        MarqueeText(text: now.title.isEmpty ? "Unknown title" : now.title)
                        // Both secondary lines truncate rather than scroll: one marquee
                        // in a 280pt popover is a detail, three would be a fairground.
                        // They stay conditional because the protocol allows either to be
                        // empty, and an empty line would just be a gap under the title.
                        if !now.artist.isEmpty {
                            Text(now.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if !now.albumLine.isEmpty {
                            // "Album · 2019", the phone's own convention: the year is
                            // album metadata, not part of the song's name, so it rides
                            // this line rather than being appended to the title — where
                            // it would scroll away with the marquee.
                            Text(now.albumLine)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
                ProgressRow(receiver: receiver)
            } else if let phone = receiver.phone {
                // Connected, but nothing has told us what is playing — a phone too old
                // for the nowPlaying frame, or one that hasn't sent the first yet.
                Label("Streaming from \(phone)", systemImage: "iphone.radiowaves.left.and.right")
                if let format = receiver.format {
                    Text(format).font(.caption).foregroundStyle(.secondary)
                }
            } else if receiver.listening, receiver.discoverability == .unlisted {
                // Bound and healthy, but Bonjour is not announcing us — so the phone's
                // picker is empty however long you stare at it. This row exists because
                // the state above it ("Waiting for Noir Player") was shown for five days
                // while exactly this was true, and it read as "nothing is wrong".
                Label("On port \(String(receiver.port)), but the phone can't see this Mac",
                      systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
            } else if receiver.listening {
                Label("Waiting for Noir Player on port \(String(receiver.port))",
                      systemImage: "wifi")
                    .foregroundStyle(.secondary)
            } else {
                Label("Not listening — is port \(String(receiver.port)) taken?",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            Divider()

            // Enabled only once the handshake agreed CONTROL — a v1 phone reads
            // nothing back, so a button that looked live would do nothing silently.
            HStack(spacing: 18) {
                Spacer()
                TransportButton("backward.fill", "Previous") { receiver.send(.previous) }
                // The phone's transport state, falling back to audible output only for
                // a phone too old to send one. `playing` alone used to drive this and
                // flickered on every skip — a flush empties the buffer, so audible goes
                // false for one prebuffer refill while the transport never paused.
                TransportButton(transportPlaying ? "pause.fill" : "play.fill",
                                transportPlaying ? "Pause" : "Play") {
                    receiver.send(transportPlaying ? .pause : .play)
                }
                TransportButton("forward.fill", "Next") { receiver.send(.next) }
                Spacer()
            }
            .disabled(!receiver.controlAvailable)
            .opacity(receiver.controlAvailable ? 1 : 0.35)
            if receiver.phone != nil && !receiver.controlAvailable {
                Text("This phone's Noir Player is too old for remote control.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            // Demoted from the headline once the song has it: still worth being able
            // to read, since "which phone, at what rate" is what you check when the
            // audio is wrong rather than absent.
            if receiver.nowPlaying != nil, let phone = receiver.phone {
                HStack(spacing: 5) {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        // Matches the symbol this row's text was labelled with before
                        // the mini player took the headline, so the meaning carries over.
                        .imageScale(.small)
                    // The phone's own name once it has sent one; the endpoint is the
                    // fallback, and an IP with an ephemeral source port is a poor label.
                    Text([receiver.deviceName ?? phone, receiver.format]
                        .compactMap { $0 }.joined(separator: " · "))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button(action: onSettings) {
                    Label("Settings…", systemImage: "gearshape")
                }
                Spacer()
                // Ends the stream from this end. Pause leaves the phone connected and the
                // device open; Quit takes the receiver with it. Neither was "stop that
                // phone", which is what someone across the room from it needs.
                if receiver.phone != nil {
                    Button("Disconnect") { receiver.disconnectPhone() }
                    Spacer()
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.link)
        }
        .padding(12)
        .frame(width: 280)
    }
}

/// Scrubber and clock.
///
/// The phone sends a position only on change, so the sweep between samples is
/// interpolated here. `TimelineView` is what drives it: it ticks only while the popover
/// is actually on screen, so a closed popover costs nothing — a `Timer` would have had
/// to be started and stopped by hand against `NSPopover.isShown`.
private struct ProgressRow: View {
    @ObservedObject var receiver: Receiver
    @State private var scrubbing = false
    @State private var scrub: Double = 0

    var body: some View {
        // durationMs of 0 is the phone saying "no scrubber" — an unprepared item, or
        // anything whose length it doesn't know.
        if let position = receiver.position, position.durationMs > 0 {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let playing = receiver.nowPlaying?.playing ?? false
                let live = scrubbing ? scrub : position.current(playing: playing)
                VStack(spacing: 0) {
                    Slider(
                        value: Binding(get: { live }, set: { scrub = $0 }),
                        in: 0...Double(position.durationMs),
                        onEditingChanged: { editing in
                            if editing {
                                // Seed before the first drag delta, or the knob jumps
                                // to whatever `scrub` held from the last scrub.
                                scrub = position.current(playing: playing)
                                scrubbing = true
                            } else {
                                scrubbing = false
                                receiver.seek(toMs: Int(scrub))
                            }
                        })
                    HStack {
                        Text(clock(live))
                        Spacer()
                        Text(clock(Double(position.durationMs)))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .disabled(!receiver.controlAvailable)
            }
        }
    }

    private func clock(_ ms: Double) -> String {
        let total = Int((ms / 1000).rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// One line that scrolls when it doesn't fit, and sits still when it does.
///
/// The width is measured with AppKit rather than a hidden SwiftUI copy: inside the
/// clipped, width-limited frame this lives in, a `Text` reports its *truncated* width,
/// and a `fixedSize` measuring copy widens the container it is measuring against. An
/// `NSString` measurement has neither problem. If it disagrees with SwiftUI's layout by
/// a point, the cost is a title that scrolls when it just fits — the harmless direction.
private struct MarqueeText: View {
    let text: String
    var weight: Font.Weight = .medium

    var body: some View {
        // `.id(text)` is the reset. Flipping `rolling` back to false on a text change
        // did not work: a `repeatForever` animation already attached to `offset` keeps
        // running, so a new song inherited the previous title's scroll mid-flight.
        // Changing the identity destroys the view and its `@State` outright, which is
        // the only reliable way to cancel one of these.
        MarqueeLine(text: text, weight: weight).id(text)
    }
}

private struct MarqueeLine: View {
    let text: String
    var weight: Font.Weight = .medium

    /// Pace, gap and lead-in are `Marquee`'s, shared with the menu bar's title.
    private static let speed = Marquee.speed
    private static let gap = Marquee.gap
    private static let leadIn = Marquee.leadIn

    @State private var rolling = false
    @ObservedObject private var prefs = Preferences.shared

    private var nsFont: NSFont {
        NSFont.systemFont(ofSize: NSFont.systemFontSize,
                          weight: weight == .medium ? .medium : .regular)
    }
    private var textWidth: CGFloat {
        (text as NSString).size(withAttributes: [.font: nsFont]).width
    }
    private var motionAllowed: Bool {
        prefs.animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        // GeometryReader, and not a plain `.frame(maxWidth:) + .clipped()`, for one
        // specific reason: `clipped()` clips *drawing* only. Two `fixedSize()` copies
        // still report the untruncated title's width up the tree, which became the
        // whole popover's ideal width and got centred inside `.frame(width: 280)` —
        // every row clipped on both edges. GeometryReader reports the size it was
        // proposed, so nothing downstream can widen its parent.
        GeometryReader { geo in
            let scrolls = textWidth > geo.size.width + 0.5 && motionAllowed
            Group {
                if scrolls {
                    HStack(spacing: Self.gap) {
                        Text(text).fontWeight(weight).fixedSize()
                        Text(text).fontWeight(weight).fixedSize()
                    }
                    .offset(x: rolling ? -(textWidth + Self.gap) : 0)
                    .animation(
                        rolling
                            ? .linear(duration: Double(textWidth + Self.gap) / Double(Self.speed))
                                .repeatForever(autoreverses: false)
                            : .none,
                        value: rolling)
                } else {
                    // Not scrolling: truncate properly rather than let `clipped()` cut
                    // a glyph in half. `fixedSize` would defeat the ellipsis, so the
                    // two branches genuinely need different text.
                    Text(text).fontWeight(weight).lineLimit(1).truncationMode(.tail)
                }
            }
            // Clamps the reported size back to the proposal; the oversized HStack
            // hangs off the leading edge and `clipped()` cuts it.
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipped()
            // No onChange(of: text) — a new title is a new view (see MarqueeText),
            // so this fires once per title, from zero, with no animation to cancel.
            .onAppear { schedule(scrolls) }
        }
        // GeometryReader has no ideal height of its own, so without this the row
        // would stretch to fill the popover.
        .frame(height: ceil(nsFont.ascender - nsFont.descender + nsFont.leading))
    }

    private func schedule(_ overflows: Bool) {
        guard overflows else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.leadIn) { rolling = true }
    }
}

/// Mini-player sized cover, decoded and bounded by the session before it gets here, so the
/// body has nothing to decode.
private struct Artwork: View {
    let image: CGImage?
    private static let side: CGFloat = 44

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(nsImage: Self.glyph)
                        .renderingMode(.template)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    /// The Blinds stand in for a missing cover — the app's own mark, already in the
    /// binary, and the same geometry the menu bar icon draws. Template-rendered, so
    /// it follows the popover's label colour instead of pinning one at first draw.
    private static let glyph: NSImage = {
        let side: CGFloat = 24
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setFillColor(NSColor.black.cgColor)
            // The compensated cut, not the display one: this is a template image, so the
            // system replaces its ink with the popover's label colour, and in light mode
            // that puts near-black bars on a light material. Both are compensation
            // triggers on their own -- see identity-system.html 02.
            BlindsGlyph.draw(in: ctx,
                             rect: CGRect(x: 0, y: 0, width: side, height: side),
                             scale: 0.85, cut: .compensated)
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }()
}

private struct TransportButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    init(_ symbol: String, _ label: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(label)
        .accessibilityLabel(label)
    }
}
