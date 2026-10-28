// The menu bar app: the receiver core behind an NSStatusItem, and the delegate that wires them.
//
// Not MenuBarExtra: its label slot renders once per *scene* invalidation and
// ignores updates published from inside the label view, which freezes the
// now-playing dance (measured at the time: engine stepping and blend=1.0 while the
// menu bar showed the resting logo). An AppKit status item whose button image is
// swapped per engine frame is the reliable way to animate up there — and its button
// is also the view the engine's display link hangs off. The popover content is still
// SwiftUI.

import AppKit
import Combine
import MediaPlayer
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var receiver: Receiver!
    private var engine: EqEngine!
    /// Owned here rather than by [EqEngine], because the receiver's tap holds it weakly and the
    /// engine is the thing that *reads* it, not the thing audio is delivered to.
    private var analyser: EqAnalyser!
    private var subs = Set<AnyCancellable>()
    private var settingsWindow: NSWindow?

    /// The song as the status item shows it, and its width, measured once per change rather
    /// than on each of the 60 frames a second the mark draws.
    private var songText: String?
    private var songWidth: CGFloat = 0
    /// **The title scrolls one pass at a time, never on a loop**: once when a song starts, and
    /// again when the item is hovered or clicked. It looped for as long as music played until
    /// 2026-10-20, and a line moving for hours in the corner of the screen wears on you. Nil
    /// between passes, when the title sits at its start with an ellipsis.
    private var pass: (start: CFTimeInterval, leadIn: Double)?
    /// Frames for a pass the mark is not already drawing — paused, or a hover with the mark at
    /// rest. Runs only for the pass's few seconds.
    private var passTimer: Timer?
    private var hover: HoverWatcher?
    /// A hover or a click is asking to read the title, so the pass starts almost at once rather
    /// than after the lead-in a new song gets.
    private static let askedLeadIn: Double = 0.3
    /// Moves the progress line while the mark is still (paused, or Animation set to Still). While
    /// the mark is moving its frames move the line, and this tick is a harmless extra.
    private var progressTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        receiver = Receiver(port: Preferences.port(), prebufferMs: Preferences.prebufferMs())
        // Before `start()`: the tap is installed when the audio engine is built, which happens on
        // the first buffer to arrive, so a watcher set afterwards would miss the first track.
        let analyser = EqAnalyser()
        receiver.onRenderedPCM = { [weak analyser] data, channels, frames, rate in
            analyser?.onAudio(data, channels: channels, frames: frames, rate: rate)
        }
        // Also before `start()`: whether the first phone to connect has to be allowed.
        for binding in Preferences.bind(receiver) { binding.store(in: &subs) }
        receiver.start()
        engine = EqEngine(receiver: receiver)
        self.analyser = analyser
        // `engine.analyser` is set by the `$reactive` subscription below, which fires immediately
        // with the stored value — so it is not assigned here as well.

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        if let button = statusItem.button {
            hover = HoverWatcher(view: button) { [weak self] in
                self?.startPass(leadIn: Self.askedLeadIn)
            }
        }

        popover.behavior = .transient
        // No show animation. `NSPopover.animates` defaults to true, which is a fade and
        // scale on every open — and next to the menu bar items people actually compare
        // this to (Docker, OneDrive, and anything else built on `NSMenu`, which does not
        // animate at all) it reads as this app being slow rather than as an effect.
        popover.animates = false
        popover.contentViewController = NSHostingController(
            rootView: ReceiverMenu(receiver: receiver,
                                   onSettings: { [weak self] in self?.openSettings() }))
        // Build the SwiftUI content now rather than on the first click. Measured: the
        // first hosting-view load costs ~36ms and every one after it ~2ms, so that
        // one-time cost otherwise lands on the user's first open after login — where it
        // is indistinguishable from the animation above, and survived turning it off.
        popover.contentViewController?.view.layoutSubtreeIfNeeded()

        // The engine steps only while the mark is moving, so this is 60fps during the
        // dance and the fuse, and silent at rest. The button is the view whose display
        // paces those frames — without it the engine falls back to a timer, so this
        // assignment is what makes the dance display-locked rather than free-running.
        engine.frameHost = statusItem.button
        engine.onFrame = { [weak self] in self?.refreshIcon() }
        // One subscription, because it is one setting. `enabled` is "move at all" and `analyser`
        // is "move to what"; the analyser keeps running either way — it is fed by the receiver's
        // tap, not by the mark — so clearing it only changes what the mark reads. Unlike the
        // phone, where the read is what keeps the analyser awake, nothing is saved by detaching
        // it: the tap comes with the audio engine and the work is a few biquads per sub-block.
        Preferences.shared.$markMotion
            .receive(on: DispatchQueue.main)
            .sink { [weak self] motion in
                guard let self else { return }
                self.engine.enabled = motion != .off
                self.engine.analyser = motion == .reactive ? self.analyser : nil
                if motion == .off { self.endPass() } // Still means still, mid-pass included
                self.refreshIcon() // settle to the resting logo immediately when off
            }
            .store(in: &subs)
        // The status item's shape. Either changing redraws it now, and the line may need its tick.
        Preferences.shared.$menuBarStyle
            .combineLatest(Preferences.shared.$progressLine)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.refreshSong()
                self?.refreshProgressTimer()
            }
            .store(in: &subs)
        // A disconnect ends the audio, so the analyser's history stops describing anything. Without
        // this the next phone to connect inherits the last track's per-band means and reads wrong
        // until they converge — and `standDown` existed unwired for a few hours precisely because
        // nothing forced the question of who calls it.
        let phone = receiver.$live.map { $0?.endpoint }.removeDuplicates()
        phone
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phone in if phone == nil { self?.analyser.standDown() } }
            .store(in: &subs)
        phone
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshIcon() }
            .store(in: &subs)
        refreshIcon()

        // The tooltip's idle text depends on both of these, and the CombineLatest4 below
        // only covers what is *playing* — so before this, "not listening" could sit in
        // the tooltip after the listener recovered, and vice versa.
        receiver.$listening
            .combineLatest(receiver.$discoverability)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.refreshTooltip() }
            .store(in: &subs)

        // A phone asking to be allowed opens the popover, because that is where Allow and
        // Deny are and nobody is looking at the menu bar when their phone starts a cast.
        // It is `.transient`, so the user's next click elsewhere closes it again — the
        // request stays pending, the tooltip says so, and the icon reopens it.
        receiver.$pendingApproval
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request in
                self?.refreshTooltip()
                if request != nil { self?.showPopover() }
            }
            .store(in: &subs)

        wireRemoteCommands()
        // Anything the system's Now Playing card shows. `position` is included because
        // Control Center draws its own scrubber from it.
        // Everything but `playing`, which flips on every seek and is the mark's business, not this.
        receiver.$live
            .removeDuplicates { a, b in
                a?.nowPlaying == b?.nowPlaying && a?.artwork === b?.artwork
                    && a?.position == b?.position && a?.controlAvailable == b?.controlAvailable
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.publishNowPlaying()
                self?.refreshTooltip()
                self?.refreshSong()
                self?.refreshProgressTimer()
            }
            .store(in: &subs)
    }

    /// Publishes to macOS's Now Playing, which is what puts this app in Control Center
    /// and makes the F7/F8/F9 keys route here. All of it is data the phone already
    /// sends — the system integration is nearly free once the metadata frames exist.
    private func publishNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let now = receiver.nowPlaying else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: now.title,
            MPMediaItemPropertyArtist: now.artist,
            MPMediaItemPropertyAlbumTitle: now.album,
            MPNowPlayingInfoPropertyPlaybackRate: now.playing ? 1.0 : 0.0,
        ]
        if let position = receiver.position, position.durationMs > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = Double(position.durationMs) / 1000
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] =
                position.current(playing: now.playing) / 1000
        }
        // Already decoded, off-main, by the session: wrapping it is free, so publishing on every
        // position frame no longer decodes the cover each time.
        if let cover = receiver.artwork {
            let image = NSImage(cgImage: cover, size: NSSize(width: cover.width, height: cover.height))
            info[MPMediaItemPropertyArtwork] =
                MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        center.nowPlayingInfo = info
        center.playbackState = now.playing ? .playing : .paused
    }

    /// Every command is disabled without a control channel, so the media keys fall
    /// through to whatever else is playing rather than silently doing nothing here.
    private func wireRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.receiver.send(.play); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.receiver.send(.pause); return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.receiver.send(self.receiver.nowPlaying?.playing == true ? .pause : .play)
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.receiver.send(.next); return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.receiver.send(.previous); return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            self.receiver.seek(toMs: Int(event.positionTime * 1000))
            return .success
        }
        receiver.$live
            .map { $0?.controlAvailable ?? false }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { available in
                for command in [center.playCommand, center.pauseCommand,
                                center.togglePlayPauseCommand, center.nextTrackCommand,
                                center.previousTrackCommand,
                                center.changePlaybackPositionCommand] {
                    command.isEnabled = available
                }
            }
            .store(in: &subs)
    }

    /// So the song is readable without opening the popover — by hovering, and by
    /// VoiceOver, which otherwise gets nothing from the mark at all: the button's only
    /// content is a template image of a dancing logo, and an unlabelled image button in
    /// the menu bar reads as no more than "button".
    private func describe(_ text: String) {
        statusItem.button?.toolTip = text
        statusItem.button?.setAccessibilityLabel(text)
    }

    private func refreshTooltip() {
        guard let now = receiver.nowPlaying else {
            if let request = receiver.pendingApproval {
                describe("\(request.displayName) wants to play on this Mac")
            } else if !receiver.listening {
                describe("Noir Receiver — not listening")
            } else if receiver.discoverability == .unlisted {
                describe("Noir Receiver — the phone can't see this Mac")
            } else {
                describe("Noir Receiver — waiting for a phone")
            }
            return
        }
        describe(now.artist.isEmpty ? now.title : "\(now.title) — \(now.artist)")
    }

    /// Re-reads the song the status item shows. On a change of song or setting, not per frame.
    private func refreshSong() {
        var text: String?
        if Preferences.shared.menuBarStyle == .song, let now = receiver.nowPlaying {
            let title = now.title.isEmpty ? "Unknown title" : now.title
            text = now.artist.isEmpty ? title : "\(title) · \(now.artist)"
        }
        if text != songText {
            songText = text
            songWidth = text.map(MenuBarLayout.textWidth) ?? 0
            pass = nil
            startPass(leadIn: Marquee.leadIn)
        }
        // `squareLength` for the mark alone, as it always was; the song's own width otherwise, so
        // the item is exactly as wide as what it shows. Only assigned on change: a new length
        // re-lays-out the whole menu bar.
        let length = songText == nil
            ? NSStatusItem.squareLength
            : MenuBarLayout.width(textWidth: songWidth) + 8
        if statusItem.length != length { statusItem.length = length }
        refreshIcon()
    }

    /// The tick the line needs when nothing else is drawing: a phone playing, the line on. One
    /// image a second, against the mark's sixty while it moves.
    private func refreshProgressTimer() {
        let needed = Preferences.shared.progressLine && receiver.nowPlaying?.playing == true
            && (receiver.position?.durationMs ?? 0) > 0
        if needed, progressTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshIcon() }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            progressTimer = timer
        } else if !needed {
            progressTimer?.invalidate()
            progressTimer = nil
        }
    }

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        var frame = MenuBarFrame(levels: engine.levels, blend: engine.blend,
                                 connected: receiver.phone != nil)
        if let now = receiver.nowPlaying, Preferences.shared.progressLine,
           let position = receiver.position, position.durationMs > 0 {
            frame.progress = CGFloat(position.current(playing: now.playing)
                                     / Double(position.durationMs))
        }
        frame.text = songText
        // One pass: the lead-in, then exactly one loop's travel, which ends with the repeat sitting
        // where the title began — so stopping there is seamless, and the ellipsis comes back.
        if let current = pass {
            let travelled = max(0, CACurrentMediaTime() - current.start - current.leadIn)
                * Double(Marquee.speed)
            if travelled < Double(songWidth + Marquee.gap) {
                frame.scroll = CGFloat(travelled)
            } else {
                endPass()
            }
        }
        button.image = menuBarImage(frame, height: NSStatusBar.system.thickness,
                                    textWidth: songText == nil ? nil : songWidth)
    }

    /// Starts a pass if the title overflows and motion is allowed, and none is running. Frames come
    /// from the mark while it moves (no extra image swaps — the swap is what costs, see
    /// `EqEngine`) and from `passTimer` otherwise.
    private func startPass(leadIn: Double) {
        guard pass == nil, songText != nil, songWidth > MenuBarLayout.maxTextWidth,
              Preferences.shared.animate,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        pass = (CACurrentMediaTime(), leadIn)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            // The mark's own frames already redraw; a second source would double the swaps.
            if !self.engine.isStepping { self.refreshIcon() }
        }
        RunLoop.main.add(timer, forMode: .common)
        passTimer = timer
    }

    private func endPass() {
        pass = nil
        passTimer?.invalidate()
        passTimer = nil
    }

    @objc private func togglePopover() {
        // A click asks what is playing as much as a hover does.
        startPass(leadIn: Self.askedLeadIn)
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard !popover.isShown, let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Settings live in a window, not in the popover and not in a sheet.
    ///
    /// The popover is `.transient`, so it closes the moment focus leaves it — which
    /// made the port field almost unusable, since clicking anything while typing threw
    /// the half-entered number away. A window also stays open while you move the buffer
    /// slider and listen to what it did, which is the only way to actually tune it.
    ///
    /// Built by hand rather than through SwiftUI's `Settings` scene: `LSUIElement`
    /// means there is no app menu, so ⌘, has nothing to hang from and the scene's only
    /// opener would be a version-dependent private selector.
    @objc private func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let hosting = NSHostingView(rootView: SettingsView(receiver: receiver))
            let window = NSWindow(contentRect: .zero,
                                  styleMask: [.titled, .closable],
                                  backing: .buffered,
                                  defer: false)
            window.title = "Noir Receiver Settings"
            // An accessory app's windows are not retained by a window controller, and
            // the default would free this one on close and crash the next open.
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.setContentSize(hosting.fittingSize)
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true) // accessory apps are never frontmost
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

/// Calls `onEnter` when the pointer enters `view`. A responder of its own because a tracking
/// area's owner receives the events, and the app delegate is not one.
final class HoverWatcher: NSResponder {
    private let onEnter: () -> Void

    init(view: NSView, onEnter: @escaping () -> Void) {
        self.onEnter = onEnter
        super.init()
        // `inVisibleRect` follows the button as the item widens for a new song, with no
        // re-adding on resize.
        view.addTrackingArea(NSTrackingArea(rect: .zero,
                                            options: [.mouseEnteredAndExited, .activeAlways,
                                                      .inVisibleRect],
                                            owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseEntered(with event: NSEvent) { onEnter() }
}
