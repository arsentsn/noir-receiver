// Noir Receiver's core: the listener, Bonjour, and which phone is live. UI-agnostic — the CLI
// (NoirReceiverCLI.swift) and the menu bar app (NoirReceiverApp.swift) both wrap this. The wire
// format is in Protocol.swift, one connection in Session.swift, audio out in Player.swift.

import Combine
import CoreGraphics
import Foundation
import IOKit.ps
import Network
import os
import SystemConfiguration

/// The receiver's own version, and the only place it is written: `build.sh` reads it out of
/// this line for the bundle's `Info.plist`, the CLI prints it for `--version`, and Settings
/// shows it — so a bug report can say which build it is about once there are downloads.
/// Semantic-ish: the middle number moves when the wire format gains a frame.
public let ReceiverVersion = "0.4.0"

/// What the buffer slider defaults to. The old default was four of the phone's ~46 ms
/// chunks, so this is that figure rounded to a number a person would pick.
public let DefaultPrebufferMs = 200

/// The one os_log handle. A `Logger` is cheap but not free to build, and every line
/// the receiver emits belongs to the same subsystem.
enum Log {
    static let receiver = Logger(subsystem: "me.arsentsn.NoirReceiver", category: "receiver")
}

// MARK: - Receiver

/// Owns the listener and publishes what a UI needs: whether we're listening, who is
/// connected, and what format is playing. Publishing happens on the main queue so
/// SwiftUI can bind directly; the CLI just reads `log`.
public final class Receiver: ObservableObject {
    /// What the phone's picker should draw this Mac as: `laptop` or `desktop`.
    ///
    /// **Decided by whether there is an internal battery, not by the model string.** The
    /// obvious test — does `hw.model` start with "MacBook" — is already broken: on Apple
    /// Silicon that string is `Mac16,1`, which names no product line at all, so a model
    /// table would need a new row for every Mac Apple ships and would be wrong for each
    /// one until someone noticed. A built-in battery *is* the laptop/desktop distinction,
    /// and the API for it has been stable since OS X 10.7.
    ///
    /// Computed once: a Mac does not grow a battery, and this is read on every re-advertise.
    static let deviceKind: String = {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return "desktop" }
        let hasInternalBattery = sources.contains { source in
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { return false }
            return desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
        return hasInternalBattery ? "laptop" : "desktop"
    }()

    /// The Mac's name as Sharing shows it, for the Bonjour record and the log.
    ///
    /// Not `Host.current().localizedName`: `Host.current()` resolves every address the Mac
    /// has, which can block for seconds, and this is read on the main queue at every start
    /// and re-advertise. The dynamic store answers from memory.
    static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }

    @Published public private(set) var listening = false

    /// Everything about the phone that is playing here, as one value: nil when none is. Was eight
    /// separate published fields, which `adopt` filled and `ended` cleared one by one — a field
    /// added to one list and not the other would have outlived its phone.
    public struct LiveState: Equatable {
        /// Where the phone connected from, `host:port`.
        public let endpoint: String
        /// The phone's user-visible name ("Sam's Galaxy"), which beats an IP and an ephemeral
        /// source port for saying *which* device is streaming.
        public var deviceName: String?
        /// "44100Hz 2ch" once the stream has started.
        public var format: String?
        /// Whether the phone agreed to the control channel. False for a v1 phone, so the
        /// transport buttons stay disabled rather than sending into a socket nobody reads.
        public var controlAvailable = false
        /// Whether sound is audibly coming out of this Mac right now — the player node is started
        /// and has buffers pending. Deliberately not "data is arriving": the phone's writes are
        /// bursty (multi-second gaps mid-song were measured, plus a flush burst right at pause),
        /// but scheduled audio drains in real time, so this tracks what the ear hears. Drives the
        /// menu bar mark's dance.
        public var playing = false
        /// What the phone says it is playing. `nowPlaying?.playing` — not `playing` above — is
        /// what a play/pause *button* should read: `playing` tracks audible output, so a flush
        /// (every seek and skip) briefly zeroes it and the icon would flick to "play" for the
        /// length of one prebuffer refill. The phone's `playWhenReady` doesn't dip.
        public var nowPlaying: NowPlaying?
        /// The cover, decoded off-main and bounded (`Session.thumbnail`). nil when the track has
        /// none.
        public var artwork: CGImage?
        /// Last position sample; interpolate with `current(playing:)` rather than reading
        /// `positionMs` directly.
        public var position: PlaybackPosition?

        public static func == (a: LiveState, b: LiveState) -> Bool {
            a.endpoint == b.endpoint && a.deviceName == b.deviceName && a.format == b.format
                && a.controlAvailable == b.controlAvailable && a.playing == b.playing
                && a.nowPlaying == b.nowPlaying && a.artwork === b.artwork
                && a.position == b.position
        }
    }
    @Published public private(set) var live: LiveState?

    // Read-only views of `live`, for the call sites that want one field and not the optional.
    public var phone: String? { live?.endpoint }
    public var deviceName: String? { live?.deviceName }
    public var format: String? { live?.format }
    public var controlAvailable: Bool { live?.controlAvailable ?? false }
    public var playing: Bool { live?.playing ?? false }
    public var nowPlaying: NowPlaying? { live?.nowPlaying }
    public var artwork: CGImage? { live?.artwork }
    public var position: PlaybackPosition? { live?.position }

    /// Whether a phone this receiver has never seen has to be allowed before it plays.
    ///
    /// Off in the core, so the CLI and every harness behave as they always did; the menu
    /// bar app switches it on from Preferences (default on there). Anyone on the same
    /// network could otherwise play audio through this Mac and push text and JPEGs at
    /// the popover — fine at home, not in a dorm or an office, and the receiver is
    /// heading for a public download. Turning it *off* while a phone is waiting allows it.
    @Published public var requireApproval = false {
        didSet {
            guard !requireApproval, let waiting = pendingSession else { return }
            adopt(waiting)
        }
    }

    /// Every phone that has been allowed or denied, by identity key (the device name,
    /// or the host for a phone that never sends one) — `true` allowed, `false` blocked.
    /// A blocked phone is closed the moment it identifies itself, with a log line, so its
    /// three reconnect attempts do not become three prompts. Persisted by the app.
    @Published public var knownPhones: [String: Bool] = [:]
    /// What each `knownPhones` key was called when it was last answered — an id key means
    /// nothing on a settings row. Missing for a key that is itself the name.
    @Published public var knownPhoneNames: [String: String] = [:]

    /// What Settings shows for a remembered phone.
    public func displayName(ofKnown key: String) -> String {
        knownPhoneNames[key] ?? key
    }

    /// A phone waiting to be allowed, or nil. Set only while `requireApproval` is on. The
    /// popover shows it with Allow and Deny; `allow()` and `deny()` answer it. One at a
    /// time — a second stranger arriving while one waits is closed, not queued.
    public struct PendingPhone: Equatable {
        public let key: String
        public let displayName: String
        public let endpoint: String
    }
    @Published public private(set) var pendingApproval: PendingPhone?
    private var pendingSession: Session?
    private var pendingExpiry: DispatchWorkItem?
    /// How long a request waits for Allow or Deny before it is closed. Settable for the CLI's
    /// `--pending-timeout`, so `protocol-test.py` can watch one expire without waiting a minute.
    public var pendingTimeout: TimeInterval = 60

    /// Connections with a session, counted on main: up in `newConnectionHandler`, down in
    /// `ended`. Every session ends through `ended`, deliberately or not.
    private var openSessions = 0
    private static let maxOpenSessions = 8
    /// So a burst past the cap logs once rather than once per refused connection.
    private var refusingConnections = false

    /// How findable this Mac is, which is *not* the same question as `listening`. A Mac
    /// that slept on one Wi-Fi network and woke on another kept a ready socket and a
    /// registration made 5d 8h earlier, while the phone could not see it at all; only
    /// quitting the app produced a fresh `DNSServiceRegister`. "The socket is bound" was
    /// the only thing the old code could report, and it is the less useful of the two.
    ///
    /// Three states rather than a bool because bound-but-not-yet-registered is a normal
    /// couple of seconds at every launch — measured at 2s once and 6s another time, the
    /// slow one resolving a name conflict first. Reported as a failure it would be a
    /// false alarm on every start, which is worse than saying nothing.
    public enum Discoverability: Equatable {
        /// Bound, waiting for Bonjour. Nothing is wrong yet.
        case registering
        /// Registered: a phone browsing `_noirplayer._tcp` will see this Mac.
        case findable
        /// Bound, and Bonjour still has not registered us well after it should have.
        /// This is the state the five-day outage sat in, invisibly.
        case unlisted
    }

    @Published public private(set) var discoverability: Discoverability = .registering

    /// The raw registration fact, kept private: `discoverability` is what a UI should
    /// read, since this one is briefly and legitimately false at every launch.
    private var advertised = false

    /// The session the transport buttons talk to. Main-queue only.
    private var liveSession: Session?

    public private(set) var port: UInt16

    /// stderr for the CLI, where a script is watching, *and* `os_log`, because a
    /// bundle launched from Finder has no stderr — it goes to `/dev/null`. Five days
    /// of the menu bar app produced zero lines anywhere on the machine before this,
    /// so the one incident it would have explained ("the phone can't see my Mac
    /// after I changed network") had to be reconstructed from Apple's own framework
    /// logging instead. Read it back with:
    ///
    ///     /usr/bin/log show --predicate 'subsystem == "me.arsentsn.NoirReceiver"' --last 1h
    ///
    /// `/usr/bin/log` spelled out: zsh has a `log` builtin that shadows it and fails
    /// with "too many arguments", which reads exactly like an empty log.
    ///
    /// `.public` is load-bearing: interpolated values are redacted to `<private>`
    /// by default, which would reduce every line here to its literal text.
    public var log: (String) -> Void = { line in
        FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
        Log.receiver.log("\(line, privacy: .public)")
    }

    /// `log` for lines that say what someone is listening to. Same stderr, but redacted in
    /// the unified log, which macOS keeps on disk for days and any admin can read: a public
    /// download should not leave a listening history there. Debugging a song line wants the
    /// CLI (or `log config` turning private data on), which is where it was always read.
    public var logListening: (String) -> Void = { line in
        FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
        Log.receiver.log("\(line, privacy: .private)")
    }

    /// Milliseconds of audio queued before playback starts. Applies to the *next*
    /// connection — a live session keeps the value it started with. Persisted by the
    /// caller. Was a count of chunks, which meant "whatever the sender's buffer size
    /// happens to be" and could not be labelled honestly on a slider.
    public var prebufferMs: Int

    private var listener: NWListener?

    private static let firstRelistenDelay: TimeInterval = 1
    private static let maxRelistenDelay: TimeInterval = 30

    /// Watches for the Mac moving between networks, which is the one transition the
    /// listener's own state machine cannot see: the socket stays `.ready` throughout.
    private var pathMonitor: NWPathMonitor?
    /// The addresses a phone could have reached us at when Bonjour last registered us.
    /// Comparing against this — rather than against the interface list — is the point:
    /// a move between two Wi-Fi networks arrives on the same `en0`, so an
    /// interface-name comparison would miss exactly the case this exists for.
    private var advertisedAddresses: Set<String> = []
    private var readvertiseWork: DispatchWorkItem?
    /// Held only between `cancel()` and its `.cancelled` callback, because dropping the
    /// last reference to a listener mid-cancellation is not a documented way to still
    /// hear about it.
    private var retiringListener: NWListener?
    private var retiringWork: DispatchWorkItem?
    private static let retireTimeout: TimeInterval = 2

    private var unlistedWork: DispatchWorkItem?
    /// How long "bound but not registered" is allowed to look normal.
    ///
    /// Deliberately far longer than it needs to be. Registration was measured landing in
    /// 2s once and 6s another time (the slow one resolved a name conflict first, which a
    /// second Mac with the same name would also do), and the two errors are not
    /// symmetric: telling someone their Mac is invisible when it is fine sends them
    /// debugging their network, while noticing a real outage ten seconds late costs
    /// nothing — the case this exists for lasted five days.
    private static let registrationGrace: TimeInterval = 15
    /// A wake onto a new network settles in several steps — three path changes inside
    /// three minutes, in the move this was diagnosed from — so let the burst finish
    /// before deciding anything.
    private static let readvertiseDebounce: TimeInterval = 2

    /// Pending relisten, so a deliberate `restart(on:)` can cancel one in flight rather
    /// than have it fire and re-bind the port we just left.
    private var relistenWork: DispatchWorkItem?
    /// Grows per consecutive failure, reset by `.ready`. Main-queue only, like the rest
    /// of this class — the listener runs on `.main`.
    private var relistenDelay: TimeInterval = Receiver.firstRelistenDelay

    /// Watch the audio this receiver is emitting — see `Player.onRenderedPCM` for why the tap is
    /// on the node and why this is a closure rather than a reference to the mark's analyser.
    ///
    /// Set it before the first stream arrives: the tap is installed when the audio engine is built,
    /// and that happens on the first buffer of a session.
    ///
    /// Stored here and handed to each `Session` as it is built, because a `Player` is per-session:
    /// a phone that disconnects and comes back gets a new one, and the watcher has to survive that.
    public var onRenderedPCM: ((UnsafePointer<UnsafeMutablePointer<Float>>, Int, Int, Float) -> Void)?

    public init(port: UInt16 = DefaultPort, prebufferMs: Int = DefaultPrebufferMs) {
        self.port = port
        self.prebufferMs = prebufferMs
    }

    public func start() {
        let params = NWParameters.tcp
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        // SO_REUSEADDR. Needed for re-advertising *while a phone is connected*: that
        // session holds the same local port, and binding a fresh listening socket over
        // it fails without this. It does not let two processes listen on the same port
        // — that would be SO_REUSEPORT — so "is the port already taken?" stays a
        // diagnosis the app can still make. Both halves verified.
        params.allowLocalEndpointReuse = true

        guard let listener = try? NWListener(using: params,
                                             on: NWEndpoint.Port(rawValue: port)!) else {
            log("cannot listen on \(port)")
            scheduleRelisten()
            return
        }
        self.listener = listener

        // A TXT record with at least one key, deliberately. Left unset, Network.framework
        // still publishes an empty TXT, and Android's NsdService parses that as an attribute
        // whose key is "" and throws `IllegalArgumentException: Key cannot be empty` on every
        // single resolve — caught and logged by the framework, so the resolve still succeeds
        // and nothing on either end looks broken.
        //
        // `v` is the protocol version from the handshake. `kind` is what the phone's picker
        // draws: it has no other way to know a Mac from a Mac mini, and drawing every
        // receiver as a laptop is wrong on screen for anything that isn't one. Same append-
        // only rule as the wire format — an older phone ignores keys it does not know, and a
        // newer phone falls back when a key is absent.
        listener.service = NWListener.Service(name: Self.computerName,
                                              type: "_noirplayer._tcp",
                                              txtRecord: NWTXTRecord([
                                                "v": String(ProtocolVersion),
                                                "kind": Self.deviceKind,
                                              ]).data)

        // The advertisement has its own lifetime, and losing it is invisible in every
        // other signal the app has: `.ready` stays ready, the port stays bound, and a
        // phone browsing for `_noirplayer._tcp` simply sees nothing.
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            guard let self else { return }
            switch change {
            // Assigned straight rather than hopped through `main.async` like the
            // connection callbacks: this handler already runs on the listener's queue,
            // which is `.main`, and a hop would let a registration from the listener
            // we just dropped land *after* `dropListener()` cleared the state.
            case .add(let endpoint):
                self.log("advertised as \(endpoint)")
                self.advertised = true
                self.unlistedWork?.cancel()
                self.unlistedWork = nil
                self.discoverability = .findable
                // Whatever we are reachable at *now* is what this registration stands
                // for; a later path change is measured against it.
                self.advertisedAddresses = Receiver.localAddresses()
            case .remove(let endpoint):
                self.log("advertisement withdrawn (\(endpoint))")
                self.advertised = false
                // A deliberate re-advertise withdraws and re-adds within milliseconds,
                // so this waits rather than flashing a warning through the popover.
                self.expectRegistration()
            @unknown default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            let endpoint = "\(conn.endpoint)"
            // Bounded, because each one is a session with a read buffer and, once allowed, an
            // audio engine — and nothing stopped anything on the network opening as many as it
            // liked. A real phone holds one, two for a second while it replaces itself.
            guard self.openSessions < Self.maxOpenSessions else {
                if !self.refusingConnections {
                    self.refusingConnections = true
                    self.log("\(Self.maxOpenSessions) connections already open; refusing more")
                }
                conn.cancel()
                return
            }
            self.openSessions += 1
            let session = Session(
                endpoint: endpoint,
                host: Receiver.host(of: conn.endpoint),
                prebufferMs: self.prebufferMs,
                onRenderedPCM: self.onRenderedPCM,
                reply: { data in conn.send(content: data, completion: .contentProcessed { _ in }) },
                // A FIN behind whatever is still queued — the status frame that says *why* —
                // and only then the cancel. `cancel()` alone can drop unsent bytes.
                terminate: {
                    conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                              completion: .contentProcessed { _ in conn.cancel() })
                },
                log: self.log,
                logListening: self.logListening)

            // **Every callback publishes only while this session is the live one.** A phone
            // waiting to be allowed, or one that was just replaced, keeps talking — and must
            // not write over what the popover says about the phone that is actually playing.
            // What it says is remembered on the session and mirrored by `adopt`.
            //
            // **`weakSession`, not `[weak session]` inside.** A capture list is evaluated where
            // the closure is made, so naming `session` there made this nested function hold it
            // strongly — and every callback below is stored *on* the session and calls this. The
            // cycle never broke: every connection leaked its session, player, buffer and cover.
            // `var`, not `let`: `weak let` is Swift 6.2+, and a source formula compiles with
            // whatever toolchain the user's Mac has (macOS 13's tops out well below that).
            weak var weakSession = session
            func ifLive(_ change: @escaping (inout LiveState) -> Void) {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let session = weakSession, self.liveSession === session,
                          self.live != nil else { return }
                    change(&self.live!)
                }
            }
            session.onPlaying = { wav in
                ifLive { $0.format = "\(Int(wav.sampleRate))Hz \(wav.channels)ch" }
            }
            session.onAudible = { audible in ifLive { $0.playing = audible } }
            session.onControl = { available in ifLive { $0.controlAvailable = available } }
            session.onNowPlaying = { np in ifLive { $0.nowPlaying = np } }
            session.onArtwork = { image in ifLive { $0.artwork = image } }
            session.onDeviceName = { name in ifLive { $0.deviceName = name } }
            session.onPosition = { position in ifLive { $0.position = position } }
            session.onIdentity = { [weak self, weak session] key, name in
                DispatchQueue.main.async {
                    guard let self, let session else { return }
                    self.identified(session, key: key, name: name)
                }
            }
            self.log("connected: \(endpoint)")
            // Decided before the first byte, on this queue (main), so the session's own
            // queue has nothing to race. Without approval the newest connection simply
            // takes over — see `adopt`.
            if self.requireApproval {
                session.hold()
            } else {
                self.adopt(session)
            }

            func receive() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                    if let data, !data.isEmpty { session.feed(data) }
                    if done || error != nil {
                        session.close() // player.stop() flips onAudible → playing=false
                        conn.cancel()
                        self.log("disconnected: \(endpoint)")
                        DispatchQueue.main.async { self.ended(session) }
                        return
                    }
                    receive()
                }
            }
            // The session's own serial queue, so its state is touched from one place — the
            // receiver hops onto it for `approve`/`decline`, never the other way round.
            conn.start(queue: session.queue)
            session.queue.async { session.armHandshakeDeadline() }
            receive()
        }

        // Every state, not just `.ready`. Handling only `.ready` meant a listener that
        // died under us left the process alive, the popover still saying "listening",
        // nothing in the log, and nothing ever retrying — the socket was simply gone.
        // A leftover CLI receiver was found in exactly that state after ~10 hours: no
        // listening socket, no line in its log after the last "disconnected".
        // `listening` is assigned directly, not hopped onto the main queue: this handler is
        // delivered on the queue `listener.start(queue:)` is given below, which is `.main`.
        // A `DispatchQueue.main.async` from the main queue is not a no-op — it defers the
        // published change by a runloop turn — so the hops that used to be here bought
        // nothing and made the arms read as if they ran off-main. Keep the hops where a
        // caller genuinely is off-main: the session callbacks above run on the session's
        // own queue. Per-call-site, not a sweep.
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.relistenDelay = Self.firstRelistenDelay
                self.log("listening on \(self.port), advertising \"\(Self.computerName)\" as _noirplayer._tcp")
                self.listening = true

            case .waiting(let error):
                // Port busy, or no usable interface yet. NWListener retries this one on
                // its own, so we log and wait rather than stacking our own timer on top.
                self.log("waiting to listen on \(self.port): \(error)")
                self.listening = false

            case .failed(let error):
                self.log("listener failed on \(self.port): \(error)")
                self.listening = false
                self.scheduleRelisten()

            case .cancelled:
                // Deliberate teardowns go through `dropListener()`, which clears this
                // handler first — so reaching here means something else killed it.
                self.log("listener cancelled unexpectedly on \(self.port)")
                self.listening = false
                self.scheduleRelisten()

            default:
                break
            }
        }

        // Seeded here as well as from the registration callback, because the callback
        // is a race: `.add` arrived 2s after start in one run and 6s in another, and
        // the path monitor's first update — which every monitor delivers immediately —
        // lands 2s in. An empty baseline at that moment reads as "the addresses
        // changed" and re-advertises a registration that is seconds old.
        advertisedAddresses = Receiver.localAddresses()
        listener.start(queue: .main)
        expectRegistration()
        startPathMonitorIfNeeded()
    }

    /// Bound, with Bonjour yet to answer: normal for a moment, a real problem if it
    /// lasts. The log line is the useful half — it names the state the five-day outage
    /// was in, which nothing could report at the time.
    private func expectRegistration() {
        discoverability = .registering
        unlistedWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.advertised, self.listener != nil else { return }
            self.log("still not registered with Bonjour \(Int(Self.registrationGrace))s "
                     + "after binding \(self.port); a phone will not find this Mac")
            self.discoverability = .unlisted
        }
        unlistedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.registrationGrace, execute: work)
    }

    /// One monitor for the process lifetime — `start()` is also the relisten and
    /// re-advertise path, and a second monitor would just double every check.
    private func startPathMonitorIfNeeded() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in self?.scheduleAddressCheck() }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    /// Re-advertises if the set of addresses a phone could reach us at has changed
    /// since Bonjour registered us.
    ///
    /// This is the fix for "I moved to another network and my phone couldn't find my
    /// Mac until I quit and reopened the receiver". `NWListener` registers the service
    /// once, when it first goes ready, and never again: measured 5d 8h 52m 53s on a
    /// single registration spanning a sleep in one place and a wake in another, with
    /// the phone connecting nine seconds after a relaunch forced a new one.
    private func scheduleAddressCheck() {
        readvertiseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let now = Receiver.localAddresses()
            guard now != self.advertisedAddresses else { return }
            // Wi-Fi going *off* is not worth a re-registration: there is nothing to be
            // findable on, and the baseline stays put so the network coming back — on
            // the same address or a different one — is still judged against what we
            // last advertised for.
            guard !now.isEmpty else { return }
            self.log("reachable at \(now.sorted().joined(separator: ", ")) — re-advertising")
            self.readvertise()
        }
        readvertiseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readvertiseDebounce, execute: work)
    }

    /// Rebuilds the listener on the same port, so Bonjour registers again. Live
    /// sessions keep their own sockets — only where the *next* connection lands
    /// changes, which is the trade `restart(on:)` already makes for a port change.
    ///
    /// Rebinding the same port has to wait for the old socket to actually be gone:
    /// `cancel()` is asynchronous, and starting straight afterwards fails with
    /// `Address already in use` — measured, twice, and `allowLocalEndpointReuse` does
    /// not rescue it, because SO_REUSEADDR does not cover a socket that is still
    /// listening. Recovery then costs a full second of the relisten backoff, which is
    /// a poor trade for fixing a stale record. `restart(on:)` never needed any of this
    /// because it only ever moves to a *different* port.
    ///
    /// The rejected alternative, for the next person who thinks of it: setting
    /// `service` to nil and back re-registers without touching the socket at all
    /// (confirmed in mDNSResponder's log), but `serviceRegistrationUpdateHandler` then
    /// goes quiet for good — no `.add` for the new record — so `advertised` would read
    /// false while the service was live, which is the exact dishonesty it exists to
    /// remove.
    private func readvertise() {
        guard let retiring = listener else {
            // Nothing bound to re-advertise on. If a previous retirement is still in
            // flight, its completion starts the next listener — binding a second one
            // here is how the `Address already in use` this method exists to avoid
            // would come back, one network change later.
            if retiringListener == nil { start() }
            return
        }
        relistenWork?.cancel()
        relistenWork = nil
        relistenDelay = Self.firstRelistenDelay

        listener = nil
        markUnadvertised()
        retiringListener = retiring
        retiring.serviceRegistrationUpdateHandler = nil
        retiring.stateUpdateHandler = { [weak self] state in
            guard let self, case .cancelled = state else { return }
            self.startAfterRetiring()
        }
        retiring.cancel()

        // A cancellation that never reports would leave the receiver with no listener
        // and nothing pending — the silent-dead-listener shape this file already has
        // one bug's worth of scar tissue about. Start anyway if the handshake stalls.
        let stall = DispatchWorkItem { [weak self] in self?.startAfterRetiring() }
        retiringWork = stall
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retireTimeout, execute: stall)
    }

    /// Called by whichever comes first: the old listener's `.cancelled`, or the stall
    /// timeout. Both routes have to be idempotent, hence the guard.
    private func startAfterRetiring() {
        guard retiringListener != nil else { return }
        retiringListener = nil
        retiringWork?.cancel()
        retiringWork = nil
        start()
    }

    /// Addresses this Mac can be reached at, as `interface:address`.
    ///
    /// Skips loopback, AWDL/link-local peer-to-peer and tunnels: a VPN coming up does
    /// not change how a phone on the same Wi-Fi reaches us, and AWDL churns on its own
    /// — 69 flow registrations in five days — which would re-advertise for nothing.
    private static func localAddresses() -> Set<String> {
        var out = Set<String>()
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return out }
        defer { freeifaddrs(head) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = ptr.pointee
            guard let addr = entry.ifa_addr,
                  entry.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let family = addr.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            let name = String(cString: entry.ifa_name)
            guard !name.hasPrefix("awdl"), !name.hasPrefix("llw"),
                  !name.hasPrefix("utun"), !name.hasPrefix("ipsec") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            // Link-local: present whether or not the network works, so it says nothing
            // about having moved.
            guard !address.hasPrefix("fe80"), !address.hasPrefix("169.254") else { continue }
            out.insert("\(name):\(address)")
        }
        return out
    }

    /// Tears the current listener down without hearing about it. Clearing the handler
    /// before `cancel()` is what keeps a deliberate teardown from looking like the
    /// listener dying — otherwise `.cancelled` would schedule a relisten against the
    /// port we are in the middle of leaving.
    private func dropListener() {
        listener?.stateUpdateHandler = nil
        listener?.serviceRegistrationUpdateHandler = nil
        listener?.cancel()
        listener = nil
        markUnadvertised()
    }

    /// Shared by every deliberate teardown. The record is gone because we dropped it, so
    /// this is `.registering`, not a warning — and any pending "still not registered"
    /// verdict belonged to the listener that just went away.
    private func markUnadvertised() {
        advertised = false
        advertisedAddresses = []
        unlistedWork?.cancel()
        unlistedWork = nil
        discoverability = .registering
    }

    /// Rebuilds the listener after a failure, backing off 1s → 2s → … → 30s. It retries
    /// indefinitely on purpose: the common causes (interface down, port held by a
    /// process that is about to exit) all come back, and a receiver that gave up would
    /// be the silent-dead-listener bug again, just with one log line in front of it.
    private func scheduleRelisten() {
        relistenWork?.cancel()
        let delay = relistenDelay
        relistenDelay = min(delay * 2, Self.maxRelistenDelay)
        log("relistening on \(port) in \(Int(delay))s")

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dropListener()
            self.start()
        }
        relistenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Sends a transport command to the connected phone. Main queue.
    public func send(_ command: Transport) {
        guard let live = liveSession else { return }
        live.queue.async { live.send(command) }
    }

    /// Asks the phone to seek. It stays the clock — this is a request, and the
    /// position that comes back is the truth.
    public func seek(toMs ms: Int) {
        guard let live = liveSession else { return }
        live.queue.async { live.seek(toMs: ms) }
    }

    // MARK: Sessions, approval

    /// Makes `session` the one the popover, the media keys and Now Playing describe.
    ///
    /// **The newest connection wins**, and the one it replaces is closed — not left playing
    /// alongside it. Before this, a second connection got a second engine: both played, both
    /// taps fed the one analyser (whose filter state is not under its lock), and the popover
    /// showed whichever wrote last. That was not hypothetical: every cast start opened two
    /// sessions a second apart (the phone's header race, fixed on its side the same day), so
    /// two engines ran for that second on every start. The replaced phone is told it was
    /// disconnected, so it does not retry — and a *different* phone cutting in therefore
    /// stays cut in rather than ping-ponging three times.
    ///
    /// Main queue. Mirrors what the session already knows, which for a phone that waited
    /// to be allowed is everything it sent meanwhile.
    private func adopt(_ session: Session) {
        if let old = liveSession, old !== session {
            log("closing \(old.endpoint): replaced by \(session.endpoint)")
            old.queue.async { old.disconnectByReceiver() }
        }
        if pendingSession === session { clearPending() }
        liveSession = session
        // A fresh value: nothing of a replaced phone carries over, `playing` included — a phone
        // that connects paused never flips audible, so an inherited `true` would dance for good.
        live = LiveState(endpoint: session.endpoint)
        session.queue.async { [weak self] in
            // Read on the session's queue, where these are written, then published on main —
            // and published *before* `approve()`, because approving opens the audio device,
            // and `engine.start()` can stall for over a second when the device is contended
            // (right after a rebuild, with another receiver's engine still winding down —
            // measured 2026-09-05 as the popover staying empty for two seconds after Allow).
            // The song, the name and the cover are known already; the speaker can catch up.
            let control = session.controlEnabled
            let format = session.format.map { "\(Int($0.sampleRate))Hz \($0.channels)ch" }
            let name = session.deviceName
            let now = session.nowPlaying
            let art = session.artwork
            let pos = session.position
            DispatchQueue.main.async {
                guard let self, self.liveSession === session, var state = self.live else { return }
                state.controlAvailable = control
                state.format = format
                state.deviceName = name
                state.nowPlaying = now
                state.artwork = art
                state.position = pos
                self.live = state // one publish, not six
            }
            session.approve()
        }
    }

    /// The session has said who it is. Main queue. Decides between adopting it, closing it
    /// as blocked, and asking — and does nothing when approval was never required, since
    /// that session was adopted the moment it connected.
    private func identified(_ session: Session, key: String, name: String) {
        // Without approval every session was adopted on connect, so one that is not live here was
        // replaced and is already being closed: nothing to ask about.
        guard requireApproval, liveSession !== session else { return }
        if let allowed = knownPhones[key] {
            if allowed {
                adopt(session)
            } else {
                log("\(name) is blocked; closing")
                session.queue.async { session.decline() }
            }
            return
        }
        if let waiting = pendingSession, waiting !== session {
            log("\(name) is asking while \(pendingApproval?.displayName ?? "another phone") already is; closing it")
            session.queue.async { session.disconnectByReceiver() }
            return
        }
        pendingSession = session
        pendingApproval = PendingPhone(key: key, displayName: name, endpoint: session.endpoint)
        log("\(name) wants to play here — waiting for Allow or Deny")
        // The request expires. There is one slot, and a request nobody answers held it for as
        // long as the asker stayed connected, closing every other phone that tried meanwhile.
        let expiry = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session, self.pendingSession === session else { return }
            self.log("\(name) was not answered in \(Int(self.pendingTimeout))s; closing it")
            self.clearPending()
            session.queue.async { session.disconnectByReceiver() }
        }
        pendingExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + pendingTimeout, execute: expiry)
    }

    /// Main queue. Every way a request stops being pending goes through here, so the expiry is
    /// cancelled with it.
    private func clearPending() {
        pendingSession = nil
        pendingApproval = nil
        pendingExpiry?.cancel()
        pendingExpiry = nil
    }

    /// Main queue, after the socket closed. Clears only what this session owned: the
    /// live phone's state if it was live, the request if it was the one asking.
    private func ended(_ session: Session) {
        openSessions -= 1
        refusingConnections = false
        if pendingSession === session { clearPending() }
        guard liveSession === session else { return }
        liveSession = nil
        live = nil
    }

    /// Answers the pending request yes: remembered, then adopted (which tells the phone).
    public func allow() {
        guard let waiting = pendingSession, let request = pendingApproval else { return }
        remember(request, allowed: true)
        log("allowed \(request.displayName)")
        adopt(waiting)
    }

    /// Answers it no: remembered as blocked, told, and closed.
    public func deny() {
        guard let waiting = pendingSession, let request = pendingApproval else { return }
        remember(request, allowed: false)
        clearPending()
        waiting.queue.async { waiting.decline() }
    }

    /// Records an answer. An answer for a phone that sent an id also drops any entry keyed by
    /// the same *name*: that is this phone's (or its twin's) answer from before ids, and left in
    /// place it would still let a name-only stranger in under it.
    private func remember(_ request: PendingPhone, allowed: Bool) {
        knownPhones[request.key] = allowed
        if request.key != request.displayName {
            knownPhones.removeValue(forKey: request.displayName)
            knownPhoneNames[request.key] = request.displayName
        }
    }

    /// Forgets an Allow or Deny, so that phone is asked again next time.
    public func forget(_ key: String) {
        knownPhones.removeValue(forKey: key)
        knownPhoneNames.removeValue(forKey: key)
    }

    /// The popover's Disconnect. The phone is told, so it neither retries nor calls it a
    /// fault; its audio falls back to its own speaker, as on any disconnect.
    public func disconnectPhone() {
        guard let live = liveSession else { return }
        log("disconnecting \(live.endpoint) from here")
        live.queue.async { live.disconnectByReceiver() }
    }

    /// The host half of a connection's endpoint, without the interface suffix Network
    /// adds to link-local and some IPv6 addresses (`fe80::1%en0`).
    private static func host(of endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "\(endpoint)" }
        let text = "\(host)"
        return text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
    }

    /// Moves the listener to a new port. Live sessions keep their sockets — only
    /// where the *next* connection lands changes, and Bonjour re-advertises it.
    public func restart(on newPort: UInt16) {
        guard newPort != port else { return }
        relistenWork?.cancel()
        relistenWork = nil
        relistenDelay = Self.firstRelistenDelay
        dropListener()
        DispatchQueue.main.async { self.listening = false }
        port = newPort
        start()
    }
}
