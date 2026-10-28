// One connection from one phone: the handshake, the stream, the frames, and what the phone has
// said about itself. Owned by `Receiver`, which decides whether it plays.

import Foundation
import ImageIO

// MARK: - Session

/// Reads the preamble (replying with the receiver's own), then the WAV header,
/// then streams everything after it to the player.
///
/// **Everything here runs on `queue`**, which is also the queue the connection delivers
/// on: the feed, `approve()`, `decline()`, the identity fallback. The `Receiver` hops here
/// (`session.queue.async`) instead of touching state from the main queue, and hops back to
/// main to publish — so nothing in this class needs a lock, and a phone that is allowed at
/// the same instant its header arrives cannot race the parse.
final class Session {
    let queue = DispatchQueue(label: "me.arsentsn.NoirReceiver.session")
    /// Where the phone connected from, as `host:port`.
    let endpoint: String
    /// The host half alone — what identifies a phone that never sends a name.
    let host: String

    private let player: Player
    private let reply: (Data) -> Void
    /// Ends the connection: a FIN behind anything already queued to send, then cancel.
    /// Exists because a session used to go `.dead` and *stay connected* — the phase
    /// stopped reading and the socket stayed open, so a garbage or future-version sender
    /// was shown as "Streaming from …" until it hung up of its own accord, and the
    /// receiver read and discarded its bytes the whole time.
    private let terminateConnection: () -> Void
    private let log: (String) -> Void
    private let logListening: (String) -> Void
    private var buffer = Data()
    private var version: UInt8 = 0
    /// `.streaming` is the v1 raw-PCM tail; `.framed` is the same audio in frames
    /// once both ends agreed CONTROL.
    private enum Phase { case preamble, confirm, header, streaming, framed, dead }
    private var phase = Phase.preamble

    /// A desync would otherwise read four bytes of music as a length. Real audio
    /// frames are a few KB.
    private let maxFrameBytes = 1 << 20

    /// True once both ends set the CONTROL bit. Guards the uplink parse *and* the
    /// downlink send: talking transport at a phone that never agreed to it would
    /// inject bytes into a socket it only ever reads a preamble from.
    private(set) var controlEnabled = false

    /// False while the receiver is waiting for someone to allow this phone. Audio is
    /// dropped and the engine is not built until `approve()`; everything else — name,
    /// song, art, position — is parsed and *remembered* below, so the popover can say who
    /// is asking and is already populated the moment the answer is yes. The phone keeps
    /// streaming meanwhile and stays the clock, so allowing it simply joins the song live.
    private(set) var approved = true
    /// The header that arrived while `approved` was false; started by `approve()`.
    private var heldWav: WavFormat?

    /// What the phone has said so far — the receiver mirrors these when it adopts the
    /// session, which may be long after they arrived (see `approved`).
    private(set) var format: WavFormat?
    private(set) var deviceName: String?
    private(set) var nowPlaying: NowPlaying?
    /// nil both before any artwork frame and after an empty one — the popover draws the
    /// placeholder either way, so the two need not be told apart here.
    private(set) var artwork: CGImage?
    private(set) var position: PlaybackPosition?

    /// Raw-path leftovers. A TCP read can end anywhere, including one byte into a sample,
    /// and the old code truncated to whole frames per read — which dropped the tail *and*
    /// shifted every later sample by that many bytes, forever. It only ever sounded right
    /// because the common segment sizes (1448, 1460) happen to divide by four. The
    /// remainder is carried to the next read instead.
    private var rawTail = Data()
    private var frameBytes = 4

    /// Fired on the main queue when `controlEnabled` settles, so the UI can enable
    /// its transport buttons.
    var onControl: ((Bool) -> Void)?
    var onPlaying: ((WavFormat) -> Void)?
    var onAudible: ((Bool) -> Void)?
    var onNowPlaying: ((NowPlaying) -> Void)?
    /// nil means the track has no art, which is a different thing from "not yet sent".
    var onArtwork: ((CGImage?) -> Void)?
    var onDeviceName: ((String) -> Void)?
    var onPosition: ((PlaybackPosition) -> Void)?
    /// Once per session, when it is known *who* this is: `(key, displayName)`. The key is
    /// the device name when the phone sends one and the host when it never will — a v1
    /// phone, or a framed one that has said nothing for a second. What the receiver
    /// remembers an Allow or Deny against.
    var onIdentity: ((String, String) -> Void)?
    private var identified = false
    /// Set by `close()`. The identity grace timer can outlive the socket, and a session that
    /// identified after closing would take the one pending-request slot for a phone that is
    /// already gone, turning away every other phone until the request expired.
    private var closed = false
    /// The phone's per-install id, hex, once its `phoneId` frame has arrived. It comes ahead of
    /// `deviceName`, so the name — which is what settles identity — finds it already here.
    private var phoneId: String?
    /// How long a framed phone gets to send its name before the host stands in for it.
    /// The phone sends `deviceName` first thing after the handshake, so this is a
    /// fallback for a phone that predates the frame, not a wait anyone normally pays.
    private static let identityGrace: TimeInterval = 1

    /// How long a connection gets to reach its WAV header. The phone needs at most ~3.5 s (the
    /// 500 ms reply wait plus `PcmStreamer.FORMAT_TIMEOUT_MS`), so this is never paid by a
    /// real phone. Without it a connection that sent nothing was held open forever, and any
    /// number of them could be.
    private static let handshakeDeadline: TimeInterval = 10

    init(endpoint: String, host: String, prebufferMs: Int,
         onRenderedPCM: ((UnsafePointer<UnsafeMutablePointer<Float>>, Int, Int, Float) -> Void)?,
         reply: @escaping (Data) -> Void,
         terminate: @escaping () -> Void,
         log: @escaping (String) -> Void,
         logListening: @escaping (String) -> Void) {
        self.endpoint = endpoint
        self.host = host
        self.player = Player(prebufferMs: prebufferMs)
        self.player.onRenderedPCM = onRenderedPCM
        self.player.log = log
        self.reply = reply
        self.terminateConnection = terminate
        self.log = log
        self.logListening = logListening
        self.player.onAudible = { [weak self] audible in self?.onAudible?(audible) }
    }

    /// Called by the receiver, on `queue`, before the first byte arrives: this phone has
    /// to be allowed before it plays.
    func hold() { approved = false }

    /// Starts the handshake clock. On `queue`, when the connection starts.
    func armHandshakeDeadline() {
        queue.asyncAfter(deadline: .now() + Self.handshakeDeadline) { [weak self] in
            guard let self else { return }
            switch self.phase {
            case .preamble, .confirm, .header:
                self.die("no WAV header \(Int(Self.handshakeDeadline))s after connecting")
            case .streaming, .framed, .dead:
                break
            }
        }
    }

    /// The answer is yes. Tells the phone (it has been showing "waiting"), and starts the
    /// audio the header described if that already arrived.
    func approve() {
        guard !approved else { return }
        approved = true
        sendStatus(.approved)
        if let wav = heldWav {
            heldWav = nil
            startPlayer(wav)
        }
    }

    /// The answer is no. The status frame goes out ahead of the FIN, so the phone can say
    /// *why* rather than "connection lost" — and can know not to retry.
    func decline() {
        sendStatus(.declined)
        log("declined \(deviceName ?? host)")
        terminateConnection()
    }

    /// Ended from this end for a reason other than refusal: the popover's Disconnect, or a
    /// newer connection taking over. Same shape as `decline`, different word on the phone.
    func disconnectByReceiver() {
        sendStatus(.disconnected)
        terminateConnection()
    }

    /// Receiver → phone. No-op unless the handshake agreed CONTROL.
    ///
    /// Logged because this is the only end of the control channel with no other
    /// witness: a media key or a Control Center button arrives through macOS, and
    /// without a line here there is no way to tell "the key never reached us" from
    /// "we sent it and the phone ignored it".
    func send(_ command: Transport) {
        guard controlEnabled, approved else { return }
        log("sending \(command)")
        reply(frame(TransportFrame, Data([command.rawValue])))
    }

    func seek(toMs ms: Int) {
        guard controlEnabled, approved else { return }
        var payload = Data()
        payload.appendLE(UInt32(clamping: max(0, ms)))
        reply(frame(SeekFrame, payload))
    }

    /// Only a phone that talks CONTROL can hear this; a v1 phone waiting to be allowed
    /// simply hears silence, which is what it heard from a receiver that was off.
    private func sendStatus(_ status: ApprovalStatus) {
        guard controlEnabled else { return }
        reply(frame(StatusFrame, Data([status.rawValue])))
    }

    /// Stops reading and closes the connection. Every `phase = .dead` goes through here.
    private func die(_ why: String) {
        log("\(why); dropping \(endpoint)")
        phase = .dead
        terminateConnection()
    }

    private func startPlayer(_ wav: WavFormat) {
        do {
            try player.start(wav)
            log("playing \(Int(wav.sampleRate))Hz \(wav.channels)ch")
            onPlaying?(wav)
        } catch {
            // Was a log line with the session left alive: `format` had been set before
            // the throw, so every later chunk retried the build and logged the same
            // failure ten times a second. A device that cannot open is the end of this
            // session.
            die("engine failed: \(error)")
        }
    }

    /// Settles who this phone is, once. The first caller wins — a name if one arrives in
    /// time, else the host.
    ///
    /// **The key is the phone's id when it sent one**, and only then its name. The name is the
    /// phone's own `device_name`, which defaults to the model ("Galaxy S25"): keyed by it, an
    /// Allow for one phone let in every stranger with the same model, and anyone could type a
    /// remembered name in. The id is random per install. It still crosses the LAN in the clear,
    /// so it stops a collision or a guess, not someone sniffing this network. A phone that
    /// predates the frame (every v1 build) is keyed by name as before.
    private func identify(_ name: String?) {
        guard !identified, !closed else { return }
        identified = true
        let display = name ?? host
        let key = phoneId.map { "id:\($0)" } ?? display
        onIdentity?(key, display)
    }

    /// Raw v1/v0 audio: whole frames to the player, the remainder carried.
    private func enqueueRaw(_ data: Data) {
        guard approved else { return }
        // The common case — nothing carried, a whole number of frames — goes straight through
        // without a copy.
        if rawTail.isEmpty, data.count % frameBytes == 0 {
            if !data.isEmpty { player.enqueue(data) }
            return
        }
        var chunk = rawTail
        chunk.append(data)
        let whole = chunk.count - chunk.count % frameBytes
        rawTail = Data(chunk[(chunk.startIndex + whole)...])
        if whole > 0 { player.enqueue(chunk.prefix(whole)) }
    }

    func feed(_ data: Data) {
        switch phase {
        case .streaming: enqueueRaw(data); return
        case .dead: return
        case .preamble, .confirm, .header, .framed: buffer.append(data)
        }

        if case .preamble = phase {
            guard buffer.count >= 4 else { return }
            if buffer.prefix(4).elementsEqual("NOIR".utf8) {
                guard buffer.count >= 8 else { return }
                version = buffer[buffer.startIndex + 4]
                guard version >= 1, version <= ProtocolVersion else {
                    die("sender speaks protocol \(version), this build tops out at \(ProtocolVersion) — update the receiver")
                    return
                }
                reply(Data("NOIR".utf8) + [ProtocolVersion, CapControl, 0, 0])
                buffer = Data(buffer.dropFirst(8))
                // A phone that also speaks CONTROL answers our offer with a preamble
                // of its own; one that doesn't goes straight to "RIFF".
                phase = .confirm
            } else if buffer.prefix(4).elementsEqual("RIFF".utf8) {
                version = 0 // pre-preamble sender; these bytes start the WAV header
                phase = .header
            } else {
                die("neither NOIR preamble nor RIFF header")
                return
            }
        }

        if case .confirm = phase {
            guard buffer.count >= 4 else { return }
            if buffer.prefix(4).elementsEqual("NOIR".utf8) {
                guard buffer.count >= 8 else { return }
                let theirCaps = buffer[buffer.startIndex + 5]
                controlEnabled = theirCaps & CapControl != 0
                buffer = Data(buffer.dropFirst(8))
                log(controlEnabled ? "control channel up" : "sender declined the control channel")
                onControl?(controlEnabled)
            } else {
                // v1 phone: it ignored our reply, so the WAV header is next and the
                // stream stays raw. Nothing to log — this is the supported old path.
                controlEnabled = false
            }
            phase = .header
        }

        if case .header = phase {
            guard buffer.count >= 44 else { return }
            guard let wav = WavFormat.parse(Data(buffer.prefix(44))) else {
                die("not a PCM WAV stream")
                return
            }
            let rest = Data(buffer.dropFirst(44))
            buffer = Data()
            format = wav
            frameBytes = 2 * Int(wav.channels)
            if approved {
                startPlayer(wav)
            } else {
                heldWav = wav
                sendStatus(.pending)
                log("holding \(Int(wav.sampleRate))Hz \(wav.channels)ch from \(endpoint) until allowed")
            }
            // Who is this? A raw phone will never say, so the host is the answer now; a
            // framed one gets a moment to send its name.
            if controlEnabled {
                queue.asyncAfter(deadline: .now() + Self.identityGrace) { [weak self] in
                    self?.identify(self?.deviceName)
                }
            } else {
                identify(nil)
            }
            if case .dead = phase { return } // startPlayer failed
            if controlEnabled {
                phase = .framed
                buffer = rest // frames resume the parse below
            } else {
                phase = .streaming
                enqueueRaw(rest)
                return
            }
        }

        if case .framed = phase {
            // **A read index, and one compaction per read.** Dropping each frame off the front
            // copied everything behind it, once per frame: a 64 KB read of empty frames is ~13k
            // frames and ~400 MB of memcpy, from anything that got through the handshake.
            var r = WireReader(buffer)
            while true {
                let start = r.offset
                guard let type = r.u8(), let length = r.u32().map(Int.init) else {
                    r.offset = start
                    break
                }
                guard length <= maxFrameBytes else {
                    die("frame claims \(length) bytes — stream desynced")
                    return
                }
                guard let payload = r.bytes(length) else {
                    r.offset = start // incomplete: wait for the rest
                    break
                }
                handle(type, payload)
                if case .dead = phase { return }
            }
            if r.offset != buffer.startIndex { buffer = Data(buffer[r.offset...]) }
        }
    }

    private func handle(_ type: UInt8, _ payload: Data) {
        switch Uplink(rawValue: type) {
        case .audio:
            guard approved else { return }
            player.enqueue(payload)
        case .flush:
            player.flush()
            note("flush")
        case .volume:
            guard let percent = payload.first else { return }
            player.setVolume(Float(min(percent, 100)) / 100)
            note("volume \(min(percent, 100))%")
        case .nowPlaying:
            guard let np = NowPlaying.parse(payload) else {
                note("malformed nowPlaying frame (\(payload.count) bytes)")
                return
            }
            let album = np.albumLine.isEmpty ? "" : " — \(np.albumLine)"
            note("now playing: \(np.title) — \(np.artist)\(album) "
                + "[\(np.playing ? "playing" : "paused")]", listening: true)
            nowPlaying = np
            onNowPlaying?(np)
        case .artwork:
            note("artwork \(payload.count) bytes")
            if payload.isEmpty {
                artwork = nil
            } else if let image = Self.thumbnail(payload) {
                artwork = image
            } else {
                note("unreadable artwork; showing none")
                artwork = nil
            }
            onArtwork?(artwork)
        case .phoneId:
            // Sanity bounds, not a format: 16 bytes from today's phone, but the key is only ever
            // compared, so any length a phone settles on works.
            guard (8...64).contains(payload.count) else {
                note("malformed phoneId frame (\(payload.count) bytes)")
                return
            }
            phoneId = payload.map { String(format: "%02x", $0) }.joined()
        case .deviceName:
            // Capped: it is shown in the Allow prompt and the tooltip, and remembered in Settings
            // for good, and the frame could otherwise carry a megabyte of it.
            guard let decoded = String(data: payload, encoding: .utf8), !decoded.isEmpty else { return }
            let name = String(decoded.prefix(Self.maxDeviceNameLength))
            note("device: \(name)")
            deviceName = name
            onDeviceName?(name)
            identify(name)
        case .position:
            guard let position = PlaybackPosition.parse(payload) else {
                log("malformed position frame (\(payload.count) bytes)")
                return
            }
            note("position \(position.positionMs)/\(position.durationMs)ms")
            self.position = position
            onPosition?(position)
        case nil:
            // A newer phone's frame type. Length-prefixing is what makes skipping it
            // safe, which is the reason audio is framed rather than left as a tail.
            note("unknown frame type \(type) (\(payload.count) bytes); ignoring")
        }
    }

    /// Characters kept of the phone's name. A real one is a model or a person's label for it.
    static let maxDeviceNameLength = 64
    /// Longest side of the decoded cover. The popover draws it at 44pt and Control Center's card
    /// not much larger, so 256 px covers a 2x display with room.
    static let artworkPixels = 256
    /// Larger than any cover a phone sends, small enough that a hostile header cannot claim a
    /// bitmap that exhausts memory.
    static let maxArtworkSide = 8192

    /// The phone's JPEG, decoded once, here, off the main queue, to a bounded thumbnail.
    ///
    /// It used to stay a `Data` and be decoded by `NSImage(data:)` on main — in the popover's
    /// body and again on every Now Playing publish, which every position frame triggers — and
    /// `NSImage` takes any ImageIO format, so a TIFF or PDF from anything on the network was
    /// parsed on the UI thread repeatedly. JPEG only, because that is all the phone sends.
    static func thumbnail(_ data: Data) -> CGImage? {
        guard data.starts(with: [0xFF, 0xD8, 0xFF]),
              let source = CGImageSourceCreateWithData(data as CFData,
                                                       [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              (1...maxArtworkSide).contains(w), (1...maxArtworkSide).contains(h) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: artworkPixels,
        ] as CFDictionary)
    }

    /// Per-frame log lines, at most `noteBudget` a second. A real phone sends a handful of these
    /// a minute; anything on the network could send thousands a read, each a line in the log.
    private func note(_ line: String, listening: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        if now - noteWindowStart >= 1_000_000_000 {
            if notesSuppressed > 0 { log("(\(notesSuppressed) frame log lines suppressed)") }
            noteWindowStart = now
            notesInWindow = 0
            notesSuppressed = 0
        }
        guard notesInWindow < Self.noteBudget else { notesSuppressed += 1; return }
        notesInWindow += 1
        (listening ? logListening : log)(line)
    }
    private static let noteBudget = 20
    private var noteWindowStart: UInt64 = 0
    private var notesInWindow = 0
    private var notesSuppressed = 0

    /// On `queue`, when the socket has closed. Says how many lines a flood had suppressed, which
    /// would otherwise wait for a next window that never comes.
    func close() {
        closed = true
        if notesSuppressed > 0 { log("(\(notesSuppressed) frame log lines suppressed)") }
        notesSuppressed = 0
        player.stop()
    }
}
